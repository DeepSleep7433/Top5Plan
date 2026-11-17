package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/t5plan/t5/server/internal/settings"
)

var ErrSourceNotFound = errors.New("one or more source records are not available on the server")

type SourceRef struct {
	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
}

type SourceRecord struct {
	EntityType string          `json:"entity_type"`
	EntityID   string          `json:"entity_id"`
	Version    int64           `json:"version"`
	Data       json.RawMessage `json:"data"`
}

type ReportScope struct {
	Kind         string         `json:"kind"`
	PeriodStart  time.Time      `json:"period_start"`
	PeriodEnd    time.Time      `json:"period_end"`
	DataCutoff   time.Time      `json:"data_cutoff"`
	Timezone     string         `json:"timezone"`
	Sources      []SourceRef    `json:"sources"`
	RecordCounts map[string]int `json:"record_counts"`
}

func (s *Service) LoadSources(ctx context.Context, refs []SourceRef) ([]SourceRecord, error) {
	if len(refs) == 0 {
		return []SourceRecord{}, nil
	}
	if len(refs) > 200 {
		return nil, errors.New("at most 200 sources may be selected")
	}
	out := make([]SourceRecord, 0, len(refs))
	for _, ref := range refs {
		var rec SourceRecord
		var data []byte
		var deleted bool
		err := s.Store.DB.QueryRowContext(ctx,
			`SELECT entity_type, entity_id, version, deleted, data FROM sync_entities
			 WHERE account_id = 1 AND entity_type = ? AND entity_id = ?`,
			ref.EntityType, ref.EntityID).Scan(&rec.EntityType, &rec.EntityID, &rec.Version, &deleted, &data)
		if err != nil || deleted || len(data) == 0 {
			return nil, ErrSourceNotFound
		}
		rec.Data = json.RawMessage(data)
		out = append(out, rec)
	}
	return out, nil
}

func (s *Service) CollectReportSources(ctx context.Context, st settings.Settings, kind string, start, end, cutoff time.Time, tz string) ([]SourceRecord, ReportScope, error) {
	excludedEntities := map[string]bool{}
	for _, id := range st.ExcludedEntityIDs {
		excludedEntities[id] = true
	}
	excludedLists := map[string]bool{}
	for _, id := range st.ExcludedLists {
		excludedLists[id] = true
	}
	rows, err := s.Store.DB.QueryContext(ctx,
		`SELECT entity_type, entity_id, version, data, server_updated_at
		 FROM sync_entities WHERE account_id = 1 AND deleted = 0 AND server_updated_at <= ?
		   AND entity_type IN ('task','decision','issue','daily_review','focus_record','daily_focus','task_list')
		 ORDER BY server_updated_at`, cutoff)
	if err != nil {
		return nil, ReportScope{}, err
	}
	defer rows.Close()
	records := []SourceRecord{}
	counts := map[string]int{}
	for rows.Next() {
		var rec SourceRecord
		var data []byte
		var updated time.Time
		if err := rows.Scan(&rec.EntityType, &rec.EntityID, &rec.Version, &data, &updated); err != nil {
			return nil, ReportScope{}, err
		}
		if len(data) == 0 || excludedEntities[rec.EntityID] {
			continue
		}
		var obj map[string]any
		if err := json.Unmarshal(data, &obj); err != nil {
			continue
		}
		if isExcludedList(obj, excludedLists) {
			continue
		}
		if !inReportPeriod(rec.EntityType, obj, start, end, tz) {
			continue
		}
		rec.Data = json.RawMessage(data)
		records = append(records, rec)
		counts[rec.EntityType]++
	}
	if err := rows.Err(); err != nil {
		return nil, ReportScope{}, err
	}
	refs := make([]SourceRef, 0, len(records))
	for _, r := range records {
		refs = append(refs, SourceRef{EntityType: r.EntityType, EntityID: r.EntityID})
	}
	scope := ReportScope{
		Kind: kind, PeriodStart: start, PeriodEnd: end, DataCutoff: cutoff,
		Timezone: tz, Sources: refs, RecordCounts: counts,
	}
	return records, scope, nil
}

func isExcludedList(obj map[string]any, excluded map[string]bool) bool {
	for _, key := range []string{"list_id", "listId"} {
		if v, ok := obj[key].(string); ok && excluded[v] {
			return true
		}
	}
	return false
}

func inReportPeriod(entityType string, obj map[string]any, start, end time.Time, tz string) bool {
	dateKeys := []string{"business_date", "businessDate", "occurrence_date", "due_date"}
	if entityType == "daily_review" || entityType == "decision" || entityType == "daily_focus" {
		for _, k := range dateKeys {
			if d, ok := obj[k].(string); ok && d != "" {
				if t, err := time.ParseInLocation("2006-01-02", d, mustLocation(tz)); err == nil {
					return !t.Before(start) && t.Before(end)
				}
			}
		}
		return false
	}
	if entityType == "focus_record" {
		for _, k := range []string{"started_at", "startedAt", "start_at"} {
			if raw, ok := obj[k].(string); ok {
				if t, err := time.Parse(time.RFC3339Nano, raw); err == nil {
					return !t.Before(start) && t.Before(end)
				}
			}
		}
		return false
	}
	if entityType == "task" {
		// Include tasks due in the period and tasks completed in the period.
		for _, k := range []string{"due_date", "dueDate"} {
			if d, ok := obj[k].(string); ok && d != "" {
				if t, err := time.ParseInLocation("2006-01-02", d, mustLocation(tz)); err == nil && !t.Before(start) && t.Before(end) {
					return true
				}
			}
		}
		for _, k := range []string{"completed_at", "completedAt"} {
			if raw, ok := obj[k].(string); ok {
				if t, err := time.Parse(time.RFC3339Nano, raw); err == nil && !t.Before(start) && t.Before(end) {
					return true
				}
			}
		}
		return false
	}
	// Issues are included when created, updated, or resolved in the period.
	for _, k := range []string{"created_at", "createdAt", "updated_at", "updatedAt", "resolved_at", "resolvedAt"} {
		if raw, ok := obj[k].(string); ok {
			if t, err := time.Parse(time.RFC3339Nano, raw); err == nil && !t.Before(start) && t.Before(end) {
				return true
			}
		}
	}
	return false
}

func mustLocation(tz string) *time.Location {
	loc, err := time.LoadLocation(tz)
	if err != nil {
		return time.FixedZone("CST", 8*3600)
	}
	return loc
}

func buildDataBlock(records []SourceRecord) string {
	var b strings.Builder
	for _, r := range records {
		data := string(r.Data)
		if len(data) > 12000 {
			data = data[:12000] + "…(truncated)"
		}
		fmt.Fprintf(&b, "\n### %s %s\n%s\n", r.EntityType, r.EntityID, data)
	}
	return b.String()
}

func (s *Service) BuildManualPrompt(ctx context.Context, instruction string, refs []SourceRef) (string, []SourceRecord, error) {
	records, err := s.LoadSources(ctx, refs)
	if err != nil {
		return "", nil, err
	}
	instruction = strings.TrimSpace(instruction)
	if instruction == "" {
		instruction = "请分析这些记录，指出关键判断、盲点和可执行的下一步。"
	}
	if len(instruction) > 4000 {
		return "", nil, errors.New("instruction is too long")
	}
	prompt := "以下是用户主动选择发送的个人记录。只基于这些事实作答；不要假装看到了未提供的记录，不要替用户做最终决定，也不要自动修改任何记录。\n\n用户问题：\n" +
		instruction + "\n\n来源记录：" + buildDataBlock(records)
	return prompt, records, nil
}

func (s *Service) BuildReportPrompt(kind, tz string, records []SourceRecord, scope ReportScope) string {
	sort.Slice(records, func(i, j int) bool {
		if records[i].EntityType == records[j].EntityType {
			return records[i].EntityID < records[j].EntityID
		}
		return records[i].EntityType < records[j].EntityType
	})
	counts, _ := json.MarshalIndent(scope.RecordCounts, "", "  ")
	period := scope.PeriodStart.In(mustLocation(tz)).Format("2006-01-02 15:04") + " — " + scope.PeriodEnd.In(mustLocation(tz)).Format("2006-01-02 15:04")
	return "生成一份个人" + map[string]string{"daily": "日报", "weekly": "周报"}[kind] + "。\n" +
		"规则：只汇总下面已同步到服务器的记录；不得把未同步内容判断为“没有记录”；不得虚构事实，不得给“决策能力”打分；" +
		"明确区分事实、模式和待验证建议；建议必须可执行。\n\n" +
		"统计周期：" + period + "（" + tz + "）\n" +
		"数据截止（UTC）：" + scope.DataCutoff.UTC().Format(time.RFC3339) + "\n" +
		"来源数量：" + fmt.Sprint(scope.RecordCounts) + "\n" +
		"记录类别计数：" + string(counts) + "\n\n来源记录：" + buildDataBlock(records)
}
