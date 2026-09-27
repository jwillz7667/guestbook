package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestEntryLifecycleAndValidation(t *testing.T) {
	app := (&guestbook{}).handler()
	for _, tc := range []struct {
		body, origin string
		want         int
	}{
		{`{"message":"Hello from Justin"}`, "", 201},
		{`{"message":"<script>alert(1)</script>"}`, "", 201},
		{`{"message":"   "}`, "", 400},
		{`{"message":"hello"}`, "https://unrelated.example", 403},
		{`{"unexpected":"hello"}`, "", 400},
		{`{"message":"hello"} {"message":"extra"}`, "", 400},
		{`{"message":"` + strings.Repeat("x", 501) + `"}`, "", 400},
	} {
		req := httptest.NewRequest("POST", "http://example.com/api/entries", strings.NewReader(tc.body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", tc.origin)
		res := httptest.NewRecorder()
		app.ServeHTTP(res, req)
		if res.Code != tc.want {
			t.Errorf("got %d want %d: %s", res.Code, tc.want, res.Body.String())
		}
	}
	res := httptest.NewRecorder()
	app.ServeHTTP(res, httptest.NewRequest("GET", "/api/entries", nil))
	if !strings.Contains(res.Body.String(), "Hello from Justin") || !strings.Contains(res.Body.String(), `\u003cscript\u003e`) {
		t.Fatal(res.Body.String())
	}
	res = httptest.NewRecorder()
	app.ServeHTTP(res, httptest.NewRequest("GET", "/env", nil))
	if res.Code != http.StatusNotFound {
		t.Fatal("environment endpoint must not be exposed")
	}
}
func TestConcurrentWritesAreBounded(t *testing.T) {
	g := &guestbook{}
	app := g.handler()
	var wg sync.WaitGroup
	for i := 0; i < 150; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req := httptest.NewRequest("POST", "/api/entries", strings.NewReader(fmt.Sprintf(`{"message":"message %d"}`, i)))
			req.Header.Set("Content-Type", "application/json")
			res := httptest.NewRecorder()
			app.ServeHTTP(res, req)
			if res.Code != 201 {
				t.Errorf("status %d", res.Code)
			}
		}(i)
	}
	wg.Wait()
	if len(g.entries) != 100 {
		t.Fatalf("got %d entries", len(g.entries))
	}
}
