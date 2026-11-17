package sync

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

var (
	ErrGenerationMismatch = errors.New("sync generation mismatch")
	ErrOperationIDReuse   = errors.New("operation_id reused with different request")
	ErrInvalidOperation   = errors.New("invalid sync operation")
)

var allowedEntityTypes = map[string]bool{
	"task": true, "task_list": true, "tag": true, "task_tag": true,
	"daily_focus": true, "decision": true, "issue": true, "daily_review": true,
	"focus_record": true, "task_series": true,
}

type Operation struct {
	OperationID string          `json:"operation_id"`
	EntityType  string          `json:"entity_type"`
	EntityID    string          `json:"entity_id"`
	BaseVersion int64           `json:"base_version"`
	Deleted     bool            `json:"deleted"`
	Payload     json.RawMessage `json:"payload,omitempty"`
}

type PushRequest struct {
	Operations []Operation `json:"operations"`
}

type Entity struct {
	EntityType      string          `json:"entity_type"`
	EntityID        string          `json:"entity_id"`
	Version         int64           `json:"version"`
	Deleted         bool            `json:"deleted"`
	Data            json.RawMessage `json:"data,omitempty"`
	ServerUpdatedAt time.Time       `json:"server_updated_at"`
}

type PushResult struct {
	OperationID   string  `json:"operation_id"`
	Accepted      bool    `json:"accepted"`
	Conflict      bool    `json:"conflict"`
	ServerVersion int64   `json:"server_version"`
	Entity        *Entity `json:"entity,omitempty"`
}

type PushResponse struct {
	Results []PushResult `json:"results"`
}

type ChangesResponse struct {
	Generation string    `json:"generation"`
	ServerTime time.Time `json:"server_time"`
	Changes    []Entity  `json:"changes"`
	NextCursor int64     `json:"next_cursor"`
	HasMore    bool      `json:"has_more"`
}

type BootstrapResponse struct {
	Generation    string    `json:"generation"`
	ServerTime    time.Time `json:"server_time"`
	SnapshotSeq   int64     `json:"snapshot_seq"`
	Entities      []Entity  `json:"entities"`
	NextAfterType string    `json:"next_after_type,omitempty"`
	NextAfterID   string    `json:"next_after_id,omitempty"`
	HasMore       bool      `json:"has_more"`
}

type Service struct {
	Store *store.Store
}

func validateOp(op Operation) error {
	if _, err := uuid.Parse(op.OperationID); err != nil {
		return fmt.Errorf("%w: operation_id must be UUID", ErrInvalidOperation)
	}
	if _, err := uuid.Parse(op.EntityID); err != nil {
		return fmt.Errorf("%w: entity_id must be UUID", ErrInvalidOperation)
	}
	if !allowedEntityTypes[op.EntityType] {
		return fmt.Errorf("%w: unsupported entity_type %q", ErrInvalidOperation, op.EntityType)
	}
	if op.BaseVersion < 0 {
		return fmt.Errorf("%w: base_version must be >= 0", ErrInvalidOperation)
	}
	if !op.Deleted {
		if len(op.Payload) == 0 || !json.Valid(op.Payload) {
			return fmt.Errorf("%w: payload must be valid JSON", ErrInvalidOperation)
		}
		var obj map[string]any
		if err := json.Unmarshal(op.Payload, &obj); err != nil {
			return fmt.Errorf("%w: payload must be a JSON object", ErrInvalidOperation)
		}
	}
	return nil
}

func requestHash(op Operation) string {
	h := sha256.New()
	fmt.Fprintf(h, "%s\x00%s\x00%s\x00%d\x00%t\x00", op.OperationID, op.EntityType, op.EntityID, op.BaseVersion, op.Deleted)
	h.Write(op.Payload)
	return hex.EncodeToString(h.Sum(nil))
}

func (s *Service) Push(ctx context.Context, deviceID string, req PushRequest) (PushResponse, error) {
	if len(req.Operations) == 0 {
		return PushResponse{Results: []PushResult{}}, nil
	}
	if len(req.Operations) > 500 {
		return PushResponse{}, fmt.Errorf("%w: too many operations", ErrInvalidOperation)
	}
	seen := map[string]bool{}
	resp := PushResponse{Results: make([]PushResult, 0, len(req.Operations))}
	for _, op := range req.Operations {
		if err := validateOp(op); err != nil {
			return PushResponse{}, err
		}
		if seen[op.OperationID] {
			return PushResponse{}, fmt.Errorf("%w: duplicate operation_id in batch", ErrInvalidOperation)
		}
		seen[op.OperationID] = true
		result, err := s.pushOne(ctx, deviceID, op)
		if err != nil {
			return PushResponse{}, err
		}
		resp.Results = append(resp.Results, result)
	}
	return resp, nil
}

func (s *Service) pushOne(ctx context.Context, deviceID string, op Operation) (PushResult, error) {
	tx, err := s.Store.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return PushResult{}, err
	}
	defer tx.Rollback()

	reqHash := requestHash(op)
	var oldHash string
	var oldResult []byte
	err = tx.QueryRowContext(ctx,
		`SELECT request_hash, result_json FROM sync_operations WHERE operation_id = ?`, op.OperationID).
		Scan(&oldHash, &oldResult)
	if err == nil {
		if oldHash != reqHash {
			return PushResult{}, ErrOperationIDReuse
		}
		var stored PushResult
		if err := json.Unmarshal(oldResult, &stored); err != nil {
			return PushResult{}, err
		}
		return stored, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return PushResult{}, err
	}

	var currentVersion int64
	var current Entity
	current.EntityType = op.EntityType
	current.EntityID = op.EntityID
	var data []byte
	var deleted bool
	var updatedAt time.Time
	err = tx.QueryRowContext(ctx,
		`SELECT version, deleted, data, server_updated_at FROM sync_entities
		 WHERE account_id = 1 AND entity_type = ? AND entity_id = ? FOR UPDATE`,
		op.EntityType, op.EntityID).
		Scan(&currentVersion, &deleted, &data, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		currentVersion = 0
	} else if err != nil {
		return PushResult{}, err
	} else {
		current.Version = currentVersion
		current.Deleted = deleted
		current.ServerUpdatedAt = updatedAt
		if len(data) > 0 {
			current.Data = json.RawMessage(data)
		}
	}

	if op.BaseVersion != currentVersion {
		result := PushResult{
			OperationID:   op.OperationID,
			Accepted:      false,
			Conflict:      true,
			ServerVersion: currentVersion,
			Entity:        &current,
		}
		raw, _ := json.Marshal(result)
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_operations(operation_id, device_id, entity_type, entity_id, request_hash, accepted, server_version, conflict, result_json, created_at)
			 VALUES(?, ?, ?, ?, ?, 0, ?, 1, ?, UTC_TIMESTAMP(6))`,
			op.OperationID, deviceID, op.EntityType, op.EntityID, reqHash, currentVersion, raw); err != nil {
			return PushResult{}, err
		}
		return result, tx.Commit()
	}

	seq, err := nextSequence(ctx, tx)
	if err != nil {
		return PushResult{}, err
	}
	newVersion := currentVersion + 1
	now := time.Now().UTC().Truncate(time.Microsecond)
	if op.Deleted {
		_, err = tx.ExecContext(ctx,
			`INSERT INTO sync_entities(account_id, entity_type, entity_id, version, deleted, data, server_updated_at)
			 VALUES(1, ?, ?, ?, 1, NULL, ?)
			 ON DUPLICATE KEY UPDATE version = VALUES(version), deleted = 1, data = NULL, server_updated_at = VALUES(server_updated_at)`,
			op.EntityType, op.EntityID, newVersion, now)
	} else {
		_, err = tx.ExecContext(ctx,
			`INSERT INTO sync_entities(account_id, entity_type, entity_id, version, deleted, data, server_updated_at)
			 VALUES(1, ?, ?, ?, 0, ?, ?)
			 ON DUPLICATE KEY UPDATE version = VALUES(version), deleted = 0, data = VALUES(data), server_updated_at = VALUES(server_updated_at)`,
			op.EntityType, op.EntityID, newVersion, []byte(op.Payload), now)
	}
	if err != nil {
		return PushResult{}, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_changes(change_seq, account_id, entity_type, entity_id, version, deleted, data, committed_at)
		 VALUES(?, 1, ?, ?, ?, ?, ?, ?)`,
		seq, op.EntityType, op.EntityID, newVersion, op.Deleted, nullableJSON(op), now); err != nil {
		return PushResult{}, err
	}
	result := PushResult{
		OperationID:   op.OperationID,
		Accepted:      true,
		Conflict:      false,
		ServerVersion: newVersion,
	}
	raw, _ := json.Marshal(result)
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_operations(operation_id, device_id, entity_type, entity_id, request_hash, accepted, server_version, conflict, result_json, created_at)
		 VALUES(?, ?, ?, ?, ?, 1, ?, 0, ?, UTC_TIMESTAMP(6))`,
		op.OperationID, deviceID, op.EntityType, op.EntityID, reqHash, newVersion, raw); err != nil {
		return PushResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return PushResult{}, err
	}
	return result, nil
}

func nullableJSON(op Operation) any {
	if op.Deleted || len(op.Payload) == 0 {
		return nil
	}
	return []byte(op.Payload)
}

func nextSequence(ctx context.Context, tx *sql.Tx) (int64, error) {
	var seq int64
	if err := tx.QueryRowContext(ctx, `SELECT next_seq FROM sync_sequence WHERE account_id = 1 FOR UPDATE`).Scan(&seq); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE sync_sequence SET next_seq = ? WHERE account_id = 1`, seq+1); err != nil {
		return 0, err
	}
	return seq, nil
}

func (s *Service) Changes(ctx context.Context, generation string, cursor int64, limit int) (ChangesResponse, error) {
	gen, err := s.Store.AccountGeneration(ctx)
	if err != nil {
		return ChangesResponse{}, err
	}
	if generation != "" && generation != gen {
		return ChangesResponse{Generation: gen}, ErrGenerationMismatch
	}
	if cursor < 0 {
		cursor = 0
	}
	if limit < 1 || limit > 2000 {
		limit = 500
	}
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT change_seq, entity_type, entity_id, version, deleted, data, committed_at
		 FROM sync_changes WHERE account_id = 1 AND change_seq > ?
		 ORDER BY change_seq ASC LIMIT ?`, cursor, limit+1)
	if err != nil {
		return ChangesResponse{}, err
	}
	defer rows.Close()
	changes := make([]Entity, 0, limit)
	next := cursor
	hasMore := false
	for rows.Next() {
		if len(changes) == limit {
			hasMore = true
			break
		}
		var e Entity
		var data []byte
		var seq int64
		if err := rows.Scan(&seq, &e.EntityType, &e.EntityID, &e.Version, &e.Deleted, &data, &e.ServerUpdatedAt); err != nil {
			return ChangesResponse{}, err
		}
		if len(data) > 0 {
			e.Data = json.RawMessage(data)
		}
		changes = append(changes, e)
		next = seq
	}
	if err := rows.Err(); err != nil {
		return ChangesResponse{}, err
	}
	return ChangesResponse{
		Generation: gen,
		ServerTime: time.Now().UTC(),
		Changes:    changes,
		NextCursor: next,
		HasMore:    hasMore,
	}, nil
}

func (s *Service) Bootstrap(ctx context.Context, afterType, afterID string, limit int) (BootstrapResponse, error) {
	gen, err := s.Store.AccountGeneration(ctx)
	if err != nil {
		return BootstrapResponse{}, err
	}
	var snapshot int64
	if err := s.Store.DB.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(change_seq), 0) FROM sync_changes WHERE account_id = 1`).Scan(&snapshot); err != nil {
		return BootstrapResponse{}, err
	}
	if limit < 1 || limit > 2000 {
		limit = 500
	}
	if afterType == "" {
		afterType = ""
		afterID = ""
	}
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT entity_type, entity_id, version, deleted, data, server_updated_at
		 FROM sync_entities WHERE account_id = 1
		   AND (entity_type > ? OR (entity_type = ? AND entity_id > ?))
		 ORDER BY entity_type, entity_id LIMIT ?`,
		afterType, afterType, afterID, limit+1)
	if err != nil {
		return BootstrapResponse{}, err
	}
	defer rows.Close()
	entities := make([]Entity, 0, limit)
	hasMore := false
	for rows.Next() {
		if len(entities) == limit {
			hasMore = true
			break
		}
		var e Entity
		var data []byte
		if err := rows.Scan(&e.EntityType, &e.EntityID, &e.Version, &e.Deleted, &data, &e.ServerUpdatedAt); err != nil {
			return BootstrapResponse{}, err
		}
		if len(data) > 0 {
			e.Data = json.RawMessage(data)
		}
		entities = append(entities, e)
	}
	if err := rows.Err(); err != nil {
		return BootstrapResponse{}, err
	}
	resp := BootstrapResponse{
		Generation:  gen,
		ServerTime:  time.Now().UTC(),
		SnapshotSeq: snapshot,
		Entities:    entities,
		HasMore:     hasMore,
	}
	if len(entities) > 0 {
		last := entities[len(entities)-1]
		resp.NextAfterType = last.EntityType
		resp.NextAfterID = last.EntityID
	}
	return resp, nil
}

func IsValidationError(err error) bool {
	return errors.Is(err, ErrInvalidOperation) || errors.Is(err, ErrOperationIDReuse)
}

func NormalizeEntityType(v string) string { return strings.TrimSpace(v) }
