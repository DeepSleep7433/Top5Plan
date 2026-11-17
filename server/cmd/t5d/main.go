package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/t5plan/t5/server/internal/ai"
	"github.com/t5plan/t5/server/internal/api"
	"github.com/t5plan/t5/server/internal/auth"
	"github.com/t5plan/t5/server/internal/config"
	"github.com/t5plan/t5/server/internal/store"
	"github.com/t5plan/t5/server/internal/updates"
)

var version = "dev"

func main() {
	mode := "serve"
	if len(os.Args) > 1 && len(os.Args[1]) > 0 && os.Args[1][0] != '-' {
		mode = os.Args[1]
		os.Args = append(os.Args[:1], os.Args[2:]...)
	}
	switch mode {
	case "serve":
		if err := serve(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d:", err)
			os.Exit(1)
		}
	case "pair":
		if err := pairingCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d pair:", err)
			os.Exit(1)
		}
	case "devices":
		if err := devicesCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d devices:", err)
			os.Exit(1)
		}
	case "revoke":
		if err := revokeCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d revoke:", err)
			os.Exit(1)
		}
	case "publish-release":
		if err := publishReleaseCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d publish-release:", err)
			os.Exit(1)
		}
	case "rotate-generation":
		if err := rotateCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "t5d rotate-generation:", err)
			os.Exit(1)
		}
	case "version":
		fmt.Println(version)
	default:
		fmt.Fprintf(os.Stderr, "unknown mode %q (serve|pair|devices|revoke|publish-release|rotate-generation|version)\n", mode)
		os.Exit(2)
	}
}

func serve() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	st, err := store.Open(ctx, cfg.DBDSN)
	if err != nil {
		return err
	}
	defer st.Close()
	if err := st.Migrate(ctx); err != nil {
		return err
	}
	svc := api.New(cfg, st, log)
	if err := svc.AI.RecoverInterrupted(ctx); err != nil {
		return err
	}
	workerCtx, stopWorker := context.WithCancel(ctx)
	defer stopWorker()
	go (&ai.Worker{Service: svc.AI, Log: log}).Run(workerCtx)
	go (&ai.Scheduler{Service: svc.AI, Log: log}).Run(workerCtx)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           svc.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	errc := make(chan error, 1)
	go func() {
		log.Info("t5d listening", "addr", cfg.Addr, "version", version)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errc <- err
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancelShutdown()
	stopWorker()
	return srv.Shutdown(shutdownCtx)
}

func dbOnly() (*store.Store, context.Context, error) {
	dsn := os.Getenv("T5_DB_DSN")
	if dsn == "" {
		return nil, nil, fmt.Errorf("T5_DB_DSN is required")
	}
	ctx := context.Background()
	st, err := store.Open(ctx, dsn)
	if err != nil {
		return nil, nil, err
	}
	if err := st.Migrate(ctx); err != nil {
		st.Close()
		return nil, nil, err
	}
	return st, ctx, nil
}

func pairingCLI() error {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	ttl := fs.Duration("ttl", 30*time.Second, "pairing code lifetime")
	fs.Parse(os.Args[1:])
	st, ctx, err := dbOnly()
	if err != nil {
		return err
	}
	defer st.Close()
	svc := &auth.Service{Store: st, TTL: *ttl}
	if err := svc.InvalidateOpenCodes(ctx); err != nil {
		return err
	}
	code, expires, err := svc.CreatePairingCode(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("Pairing code: %s\nExpires at: %s\nUse once from the client. This code is not stored in plaintext.\n", code, expires.Format(time.RFC3339))
	return nil
}

func devicesCLI() error {
	st, ctx, err := dbOnly()
	if err != nil {
		return err
	}
	defer st.Close()
	devices, err := (&auth.Service{Store: st}).ListDevices(ctx)
	if err != nil {
		return err
	}
	for _, d := range devices {
		status := "active"
		if d.RevokedAt != nil {
			status = "revoked"
		}
		fmt.Printf("%s\t%s\t%s\t%s\n", d.ID, d.Name, d.Platform, status)
	}
	return nil
}

func revokeCLI() error {
	fs := flag.NewFlagSet("revoke", flag.ExitOnError)
	id := fs.String("id", "", "device id")
	fs.Parse(os.Args[1:])
	if *id == "" {
		return fmt.Errorf("-id is required")
	}
	st, ctx, err := dbOnly()
	if err != nil {
		return err
	}
	defer st.Close()
	if err := (&auth.Service{Store: st}).RevokeDevice(ctx, *id); err != nil {
		return err
	}
	fmt.Println("revoked", *id)
	return nil
}

func rotateCLI() error {
	st, ctx, err := dbOnly()
	if err != nil {
		return err
	}
	defer st.Close()
	gen, err := st.RotateGeneration(ctx)
	if err != nil {
		return err
	}
	fmt.Println("new sync generation:", gen)
	fmt.Println("Clients will detect generation_mismatch, preserve local data, and bootstrap the server mirror again.")
	return nil
}

func publishReleaseCLI() error {
	fs := flag.NewFlagSet("publish-release", flag.ExitOnError)
	platform := fs.String("platform", "", "windows or android")
	version := fs.String("version", "", "release version, e.g. 1.0.1")
	downloadURL := fs.String("url", "", "download URL")
	sha := fs.String("sha256", "", "optional SHA-256 of download")
	notes := fs.String("notes", "", "release notes")
	mandatory := fs.Bool("mandatory", false, "mark this release mandatory")
	channel := fs.String("channel", "stable", "stable or beta")
	fs.Parse(os.Args[1:])
	st, ctx, err := dbOnly()
	if err != nil {
		return err
	}
	defer st.Close()
	r, err := (&updates.Service{Store: st}).Publish(ctx, updates.PublishInput{
		Platform: *platform, Version: *version, DownloadURL: *downloadURL,
		SHA256: *sha, ReleaseNotes: *notes, Mandatory: *mandatory, Channel: *channel,
	})
	if err != nil {
		return err
	}
	fmt.Printf("published %s %s channel=%s download=%s\n", r.Platform, r.Version, r.Channel, r.DownloadURL)
	return nil
}
