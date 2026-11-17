package migrations

import "embed"

// Files contains ordered SQL migrations. Add only forward migrations; never edit
// a migration that has shipped to production.
//
//go:embed *.sql
var Files embed.FS

const LatestVersion = 2
