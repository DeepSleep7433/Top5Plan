package integration

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/t5plan/t5/server/internal/sync"
)

func op(t *testing.T, id, entityID string, base int64, payload map[string]any, deleted bool) sync.Operation {
	t.Helper()
	var raw json.RawMessage
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		raw = b
	}
	return sync.Operation{
		OperationID: id,
		EntityType:  "task",
		EntityID:    entityID,
		BaseVersion: base,
		Deleted:     deleted,
		Payload:     raw,
	}
}

func TestPushIsIdempotentAndVersioned(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &sync.Service{Store: st}
	entityID := mustUUID(t)
	opID := mustUUID(t)
	first := op(t, opID, entityID, 0, map[string]any{"title": "第一条", "status": 0}, false)

	resp, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{first}})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Results[0].Accepted || resp.Results[0].ServerVersion != 1 {
		t.Fatalf("unexpected first result: %+v", resp.Results[0])
	}

	// A retry with the same immutable operation id must not create a second
	// version or change the entity.
	retry, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{first}})
	if err != nil {
		t.Fatal(err)
	}
	if retry.Results[0].ServerVersion != 1 || !retry.Results[0].Accepted {
		t.Fatalf("unexpected retry: %+v", retry.Results[0])
	}
	var versions int
	if err := st.DB.QueryRow(`SELECT COUNT(*) FROM sync_changes WHERE entity_id=?`, entityID).Scan(&versions); err != nil {
		t.Fatal(err)
	}
	if versions != 1 {
		t.Fatalf("change count = %d, want 1", versions)
	}

	// A different device based on version 0 must receive a conflict and the
	// current server entity rather than overwrite it.
	conflict, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{
		op(t, mustUUID(t), entityID, 0, map[string]any{"title": "离线编辑"}, false),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !conflict.Results[0].Conflict || conflict.Results[0].ServerVersion != 1 {
		t.Fatalf("expected conflict: %+v", conflict.Results[0])
	}
	if conflict.Results[0].Entity == nil || string(conflict.Results[0].Entity.Data) == "" {
		t.Fatal("conflict must include current server entity")
	}

	// Rebase onto the latest version and retry.
	update := op(t, mustUUID(t), entityID, 1, map[string]any{"title": "合并后第二版"}, false)
	updated, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{update}})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Results[0].Accepted || updated.Results[0].ServerVersion != 2 {
		t.Fatalf("unexpected update: %+v", updated.Results[0])
	}

	// Delete and verify a long-offline base version cannot resurrect the row.
	deletedOp := op(t, mustUUID(t), entityID, 2, nil, true)
	deleted, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{deletedOp}})
	if err != nil || !deleted.Results[0].Accepted {
		t.Fatalf("delete: %+v %v", deleted.Results, err)
	}
	stale, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{
		op(t, mustUUID(t), entityID, 1, map[string]any{"title": "僵尸复活"}, false),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !stale.Results[0].Conflict || stale.Results[0].Entity == nil || !stale.Results[0].Entity.Deleted {
		t.Fatalf("stale update must not resurrect: %+v", stale.Results[0])
	}
}

func TestPushOperationIDReuseRejected(t *testing.T) {
	st := testStore(t)
	svc := &sync.Service{Store: st}
	ctx := context.Background()
	entityID := mustUUID(t)
	opID := mustUUID(t)
	first := op(t, opID, entityID, 0, map[string]any{"title": "A"}, false)
	if _, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{first}}); err != nil {
		t.Fatal(err)
	}
	changed := op(t, opID, entityID, 0, map[string]any{"title": "B"}, false)
	_, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{changed}})
	if !errors.Is(err, sync.ErrOperationIDReuse) {
		t.Fatalf("got %v, want ErrOperationIDReuse", err)
	}
}

func TestChangesPaginationAndGeneration(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &sync.Service{Store: st}
	deviceID := mustUUID(t)
	for i := 0; i < 5; i++ {
		_, err := svc.Push(ctx, deviceID, sync.PushRequest{Operations: []sync.Operation{
			op(t, mustUUID(t), mustUUID(t), 0, map[string]any{"title": "任务", "n": i}, false),
		}})
		if err != nil {
			t.Fatal(err)
		}
	}
	gen, _ := st.AccountGeneration(ctx)
	cursor := int64(0)
	seen := map[string]bool{}
	for pages := 0; pages < 10; pages++ {
		page, err := svc.Changes(ctx, gen, cursor, 2)
		if err != nil {
			t.Fatal(err)
		}
		if len(page.Changes) > 2 {
			t.Fatalf("page too large: %d", len(page.Changes))
		}
		for _, c := range page.Changes {
			if seen[c.EntityID] {
				t.Fatalf("duplicate entity in pagination: %s", c.EntityID)
			}
			seen[c.EntityID] = true
		}
		cursor = page.NextCursor
		if !page.HasMore {
			break
		}
	}
	if len(seen) != 5 {
		t.Fatalf("saw %d entities, want 5", len(seen))
	}
	newGen, err := st.RotateGeneration(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = svc.Changes(ctx, gen, 0, 10)
	if !errors.Is(err, sync.ErrGenerationMismatch) {
		t.Fatalf("got %v, want generation mismatch (new %s)", err, newGen)
	}
}

func TestBootstrapPagesCurrentMirror(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &sync.Service{Store: st}
	for i := 0; i < 4; i++ {
		_, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{
			op(t, mustUUID(t), mustUUID(t), 0, map[string]any{"title": "任务"}, false),
		}})
		if err != nil {
			t.Fatal(err)
		}
	}
	var afterType, afterID string
	total := 0
	for i := 0; i < 10; i++ {
		page, err := svc.Bootstrap(ctx, afterType, afterID, 2)
		if err != nil {
			t.Fatal(err)
		}
		total += len(page.Entities)
		if !page.HasMore {
			break
		}
		afterType, afterID = page.NextAfterType, page.NextAfterID
	}
	if total != 4 {
		t.Fatalf("bootstrap entities = %d", total)
	}
}

func TestServerIgnoresClientTimestampsForOrdering(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	svc := &sync.Service{Store: st}
	id := mustUUID(t)
	// A device clock far in the past must not prevent a valid versioned write.
	first := op(t, mustUUID(t), id, 0, map[string]any{
		"title":      "客户端时钟在 1999",
		"updated_at": "1999-01-01T00:00:00Z",
	}, false)
	resp, err := svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{first}})
	if err != nil || !resp.Results[0].Accepted {
		t.Fatalf("past clock push: %+v %v", resp, err)
	}
	// A device clock in the future still cannot override a stale base_version.
	future := op(t, mustUUID(t), id, 0, map[string]any{
		"title":      "客户端时钟在 2099",
		"updated_at": "2099-01-01T00:00:00Z",
	}, false)
	resp, err = svc.Push(ctx, mustUUID(t), sync.PushRequest{Operations: []sync.Operation{future}})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.Results[0].Conflict {
		t.Fatalf("future clock should not force overwrite: %+v", resp.Results[0])
	}
}
