// Copyright 2014 The Kubernetes Authors.
// Licensed under the Apache License, Version 2.0.
// See the repository LICENSE file.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// Entries are intentionally ephemeral and local to each replica in this lab.
// A shared database is required before using a scaled deployment for durable data.
type guestbook struct {
	mu      sync.RWMutex
	entries []string
}

func (g *guestbook) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/entries", func(w http.ResponseWriter, r *http.Request) {
		g.mu.RLock()
		entries := append([]string{}, g.entries...)
		g.mu.RUnlock()
		writeJSON(w, http.StatusOK, entries)
	})
	mux.HandleFunc("POST /api/entries", func(w http.ResponseWriter, r *http.Request) {
		// Browser writes must originate from this application.
		if raw := r.Header.Get("Origin"); raw != "" {
			origin, err := url.Parse(raw)
			if err != nil || origin.Host != r.Host || (origin.Scheme != "https" && origin.Scheme != "http") {
				http.Error(w, "Origin not allowed", http.StatusForbidden)
				return
			}
		}
		if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
			http.Error(w, "Use application/json", http.StatusUnsupportedMediaType)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		var input struct {
			Message string `json:"message"`
		}
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil {
			http.Error(w, "Invalid message", http.StatusBadRequest)
			return
		}
		if err := decoder.Decode(&struct{}{}); err != io.EOF {
			http.Error(w, "Provide exactly one JSON message", http.StatusBadRequest)
			return
		}
		input.Message = strings.TrimSpace(input.Message)
		if input.Message == "" || !utf8.ValidString(input.Message) || utf8.RuneCountInString(input.Message) > 500 {
			http.Error(w, "Enter a message of 1 to 500 characters", http.StatusBadRequest)
			return
		}
		g.mu.Lock()
		if len(g.entries) >= 100 {
			g.entries = g.entries[1:]
		}
		g.entries = append(g.entries, input.Message)
		entries := append([]string{}, g.entries...)
		g.mu.Unlock()
		writeJSON(w, http.StatusCreated, entries)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	mux.Handle("GET /", http.FileServer(http.Dir("public")))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; object-src 'none'; base-uri 'self'")
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

func main() {
	app := &guestbook{}
	server := &http.Server{Addr: ":3000", Handler: app.handler(), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		deadline, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(deadline); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()
	log.Print("Guestbook listening on port 3000")
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
