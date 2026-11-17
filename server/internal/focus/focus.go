package focus

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/t5plan/t5/server/internal/store"
)

var (
	ErrActiveSession  = errors.New("an active focus session already exists")
	ErrVersionStale   = errors.New("focus session version is stale")
	ErrNotController  = errors.New("this device does not control the focus session")
	ErrInvalidCommand = errors.New("invalid focus command")
)

type Session struct {
	ID              string     `json:"id"`
	TaskID          *string    `json:"task_id,omitempty"`
	Label           string     `json:"label"`
	TargetSeconds   int        `json:"target_seconds"`
	State           string     `json:"state"`
	AccumulatedMS   int64      `json:"accumulated_ms"`
	RunningSince    *time.Time `json:"running_since,omitempty"`
	ControlDeviceID string     `json:"control_device_id"`
	Version         int64      `json:"version"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
	ElapsedMS       int64      `json:"elapsed_ms"`
	RemainingMS     int64      `json:"remaining_ms"`
}

type CurrentResponse struct {
	Session    *Session  `json:"session"`
	ServerTime time.Time `json:"server_time"`
}

type CommandRequest struct {
	Action          string  `json:"action"`
	ExpectedVersion int64   `json:"expected_version"`
	SessionID       string  `json:"session_id,omitempty"`
	TaskID          *string `json:"task_id,omitempty"`
	Label           string  `json:"label,omitempty"`
	TargetSeconds   int     `json:"target_seconds,omitempty"`
}

type Service struct {
	Store *store.Store
}

func (s *Service) Current(ctx context.Context) (CurrentResponse, error) {
	row := s.Store.DB.QueryRowContext(ctx,
		`SELECT id, task_id, label, target_seconds, state, accumulated_ms, running_since,
		        control_device_id, version, created_at, updated_at
		 FROM focus_sessions WHERE account_id = 1 AND state IN ('running','paused')
		 ORDER BY updated_at DESC LIMIT 1`)
	sess, err := scanSession(row)
	if errors.Is(err, sql.ErrNoRows) {
		return CurrentResponse{ServerTime: time.Now().UTC()}, nil
	}
	if err != nil {
		return CurrentResponse{}, err
	}
	fillDerived(sess, time.Now().UTC())
	return CurrentResponse{Session: sess, ServerTime: time.Now().UTC()}, nil
}

func (s *Service) Command(ctx context.Context, deviceID string, req CommandRequest) (CurrentResponse, error) {
	if req.ExpectedVersion < 0 {
		return CurrentResponse{}, fmt.Errorf("%w: expected_version", ErrInvalidCommand)
	}
	tx, err := s.Store.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return CurrentResponse{}, err
	}
	defer tx.Rollback()

	if req.Action == "start" {
		if req.TargetSeconds < 1 || req.TargetSeconds > 86400 {
			return CurrentResponse{}, fmt.Errorf("%w: target_seconds", ErrInvalidCommand)
		}
		var existing string
		err := tx.QueryRowContext(ctx,
			`SELECT id FROM focus_sessions WHERE account_id = 1 AND state IN ('running','paused') FOR UPDATE`).Scan(&existing)
		if err == nil {
			return CurrentResponse{}, ErrActiveSession
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return CurrentResponse{}, err
		}
		now := time.Now().UTC().Truncate(time.Microsecond)
		id := uuid.NewString()
		var task any
		if req.TaskID != nil && *req.TaskID != "" {
			if _, err := uuid.Parse(*req.TaskID); err != nil {
				return CurrentResponse{}, fmt.Errorf("%w: task_id", ErrInvalidCommand)
			}
			task = *req.TaskID
		}
		if len(req.Label) > 200 {
			return CurrentResponse{}, fmt.Errorf("%w: label", ErrInvalidCommand)
		}
		_, err = tx.ExecContext(ctx,
			`INSERT INTO focus_sessions(id, account_id, task_id, label, target_seconds, state, accumulated_ms,
			  running_since, control_device_id, version, created_at, updated_at)
			 VALUES(?, 1, ?, ?, ?, 'running', 0, ?, ?, 1, ?, ?)`,
			id, task, req.Label, req.TargetSeconds, now, deviceID, now, now)
		if err != nil {
			return CurrentResponse{}, err
		}
		if err := tx.Commit(); err != nil {
			return CurrentResponse{}, err
		}
		return s.Current(ctx)
	}

	sess, err := scanSession(tx.QueryRowContext(ctx,
		`SELECT id, task_id, label, target_seconds, state, accumulated_ms, running_since,
		        control_device_id, version, created_at, updated_at
		 FROM focus_sessions WHERE account_id = 1 AND state IN ('running','paused')
		 ORDER BY updated_at DESC LIMIT 1 FOR UPDATE`))
	if errors.Is(err, sql.ErrNoRows) {
		return CurrentResponse{}, fmt.Errorf("%w: no active session", ErrVersionStale)
	}
	if err != nil {
		return CurrentResponse{}, err
	}
	if req.SessionID != "" && req.SessionID != sess.ID {
		return CurrentResponse{}, fmt.Errorf("%w: session_id", ErrVersionStale)
	}
	if req.ExpectedVersion != sess.Version {
		return CurrentResponse{}, ErrVersionStale
	}
	if req.Action != "takeover" && sess.ControlDeviceID != deviceID {
		return CurrentResponse{}, ErrNotController
	}

	now := time.Now().UTC().Truncate(time.Microsecond)
	newState := sess.State
	newControl := sess.ControlDeviceID
	accumulated := sess.AccumulatedMS
	runningSince := sess.RunningSince
	ended := false
	switch req.Action {
	case "takeover":
		newControl = deviceID
	case "pause":
		if sess.State == "paused" {
			return CurrentResponse{}, fmt.Errorf("%w: already paused", ErrInvalidCommand)
		}
		accumulated = elapsedMS(sess, now)
		runningSince = nil
		newState = "paused"
	case "resume":
		if sess.State != "paused" {
			return CurrentResponse{}, fmt.Errorf("%w: not paused", ErrInvalidCommand)
		}
		runningSince = &now
		newState = "running"
	case "end":
		accumulated = elapsedMS(sess, now)
		runningSince = nil
		newState = "ended"
		ended = true
	default:
		return CurrentResponse{}, fmt.Errorf("%w: unsupported action", ErrInvalidCommand)
	}
	if ended {
		_, err = tx.ExecContext(ctx,
			`UPDATE focus_sessions SET state = 'ended', accumulated_ms = ?, running_since = NULL,
			 control_device_id = ?, version = version + 1, updated_at = ?, ended_at = ? WHERE id = ?`,
			accumulated, newControl, now, now, sess.ID)
	} else {
		_, err = tx.ExecContext(ctx,
			`UPDATE focus_sessions SET state = ?, accumulated_ms = ?, running_since = ?,
			 control_device_id = ?, version = version + 1, updated_at = ? WHERE id = ?`,
			newState, accumulated, runningSince, newControl, now, sess.ID)
	}
	if err != nil {
		return CurrentResponse{}, err
	}
	if err := tx.Commit(); err != nil {
		return CurrentResponse{}, err
	}
	if ended {
		return CurrentResponse{Session: nil, ServerTime: now}, nil
	}
	return s.Current(ctx)
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanSession(row rowScanner) (*Session, error) {
	var sess Session
	var taskID sql.NullString
	var running sql.NullTime
	err := row.Scan(&sess.ID, &taskID, &sess.Label, &sess.TargetSeconds, &sess.State,
		&sess.AccumulatedMS, &running, &sess.ControlDeviceID, &sess.Version, &sess.CreatedAt, &sess.UpdatedAt)
	if err != nil {
		return nil, err
	}
	if taskID.Valid {
		v := taskID.String
		sess.TaskID = &v
	}
	if running.Valid {
		v := running.Time
		sess.RunningSince = &v
	}
	return &sess, nil
}

func elapsedMS(sess *Session, now time.Time) int64 {
	ms := sess.AccumulatedMS
	if sess.State == "running" && sess.RunningSince != nil {
		d := now.Sub(*sess.RunningSince)
		if d > 0 {
			ms += d.Milliseconds()
		}
	}
	return ms
}

func fillDerived(sess *Session, now time.Time) {
	sess.ElapsedMS = elapsedMS(sess, now)
	remain := int64(sess.TargetSeconds)*1000 - sess.ElapsedMS
	if remain < 0 {
		remain = 0
	}
	sess.RemainingMS = remain
}
