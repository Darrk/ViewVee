package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
)

func TestTURNEndpointWithIdentityServer(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	var issuer *httptest.Server
	issuer = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/openid-configuration":
			writeJSON(w, 200, map[string]any{"issuer": issuer.URL, "jwks_uri": issuer.URL + "/keys", "id_token_signing_alg_values_supported": []string{"RS256"}})
		case "/keys":
			writeJSON(w, 200, jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "test", Algorithm: "RS256", Use: "sig"}}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer issuer.Close()
	cfg := turnConfig{secret: strings.Repeat("s", 32), issuer: issuer.URL, audience: "viewvee-api", scope: "viewvee-api", urls: []string{"turns:turn.viewvee.com:443?transport=tcp"}, ttl: time.Hour, origins: []string{"https://app.viewvee.com"}}
	verify, err := newIdentityVerifier(context.Background(), cfg.issuer, cfg.audience)
	if err != nil {
		t.Fatal(err)
	}
	service, err := newTURNService(context.Background(), cfg, verify)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Truncate(time.Second)
	service.now = func() time.Time { return now }
	handler := newHandler(config{staticDir: "web"}, &fakeSender{}, service)
	sign := func(claims map[string]any, signingKey *rsa.PrivateKey) string {
		t.Helper()
		signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: jose.JSONWebKey{Key: signingKey, KeyID: "test"}}, nil)
		if err != nil {
			t.Fatal(err)
		}
		payload, _ := json.Marshal(claims)
		signed, err := signer.Sign(payload)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := signed.CompactSerialize()
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	claims := func() map[string]any {
		return map[string]any{"iss": issuer.URL, "aud": "viewvee-api", "sub": "user-42", "exp": now.Add(time.Hour).Unix(), "nbf": now.Add(-time.Minute).Unix(), "scope": "openid viewvee-api"}
	}
	for _, tc := range []struct {
		name   string
		change func(map[string]any)
		status int
	}{
		{"valid", func(map[string]any) {}, 200},
		{"array scope", func(c map[string]any) { c["scope"] = []string{"openid", "viewvee-api"} }, 200},
		{"wrong audience", func(c map[string]any) { c["aud"] = "other-api" }, 401},
		{"wrong issuer", func(c map[string]any) { c["iss"] = "https://other.example" }, 401},
		{"expired", func(c map[string]any) { c["exp"] = now.Add(-time.Minute).Unix() }, 401},
		{"not yet valid", func(c map[string]any) { c["nbf"] = now.Add(time.Hour).Unix() }, 401},
		{"missing subject", func(c map[string]any) { delete(c, "sub") }, 401},
		{"ID token without scope", func(c map[string]any) { delete(c, "scope") }, 401},
		{"wrong scope", func(c map[string]any) { c["scope"] = "openid other-api" }, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := claims()
			tc.change(c)
			r := httptest.NewRequest("GET", "/api/turn/credentials", nil)
			r.Header.Set("Authorization", "Bearer "+sign(c, key))
			r.Header.Set("Origin", "https://app.viewvee.com")
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("got %d: %s", w.Code, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("credentials must not be cached")
			}
			if w.Header().Get("Access-Control-Allow-Origin") != "https://app.viewvee.com" {
				t.Fatal("missing allowed CORS origin")
			}
			if tc.status == 200 {
				var body struct {
					URLs       []string  `json:"urls"`
					Username   string    `json:"username"`
					Credential string    `json:"credential"`
					ExpiresAt  time.Time `json:"expiresAt"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if len(body.URLs) != 1 || body.URLs[0] != cfg.urls[0] || !body.ExpiresAt.Equal(now.Add(time.Hour)) {
					t.Fatalf("wrong response: %s", w.Body.String())
				}
				mac := hmac.New(sha1.New, []byte(cfg.secret))
				mac.Write([]byte(body.Username))
				if body.Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
					t.Fatal("credential does not match Coturn HMAC")
				}
				if strings.Contains(w.Body.String(), cfg.secret) || strings.Contains(body.Username, "user-42") {
					t.Fatal("secret or identity leaked")
				}
			}
		})
	}
	badKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	r := httptest.NewRequest("GET", "/api/turn/credentials", nil)
	r.Header.Set("Authorization", "Bearer "+sign(claims(), badKey))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatalf("invalid signature accepted: %d", w.Code)
	}
}

func TestTURNEndpointAccessAndRateLimit(t *testing.T) {
	s := &turnService{config: turnConfig{secret: strings.Repeat("s", 32), scope: "viewvee-api", ttl: time.Hour, urls: []string{"turns:turn.viewvee.com:443?transport=tcp"}, origins: []string{"https://app.viewvee.com"}}, now: time.Now, windows: make(map[string]issuanceWindow), verify: func(context.Context, string) (turnIdentity, error) {
		return turnIdentity{"user", []string{"viewvee-api"}}, nil
	}}
	handler := newHandler(config{staticDir: "web"}, &fakeSender{}, s)
	request := func(method, token, origin string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/turn/credentials", nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	if w := request("GET", "", ""); w.Code != 401 {
		t.Fatal("missing token accepted")
	}
	if w := request("OPTIONS", "", "https://app.viewvee.com"); w.Code != 204 {
		t.Fatal("preflight failed")
	}
	if w := request("GET", "token", "https://evil.example"); w.Code != 403 {
		t.Fatal("untrusted origin accepted")
	}
	for i := 0; i < 60; i++ {
		if w := request("GET", "token", ""); w.Code != 200 {
			t.Fatalf("request %d failed", i)
		}
	}
	if w := request("GET", "token", ""); w.Code != 429 {
		t.Fatal("rate limit not enforced")
	}
	s.now = func() time.Time { return time.Now().Add(2 * time.Hour) }
	if w := request("GET", "token", ""); w.Code != 200 {
		t.Fatal("rate limit did not expire")
	}
	disabled := newHandler(config{staticDir: "web"}, &fakeSender{})
	w := httptest.NewRecorder()
	disabled.ServeHTTP(w, httptest.NewRequest("GET", "/api/turn/credentials", nil))
	if w.Code != 503 {
		t.Fatal("disabled endpoint should fail closed")
	}
}

func TestTURNConfigValidation(t *testing.T) {
	t.Setenv("TURN_SHARED_SECRET", strings.Repeat("s", 32))
	for _, tc := range []struct{ key, value string }{
		{"TURN_SHARED_SECRET", "short"}, {"TURN_CREDENTIAL_TTL_SECONDS", "0"}, {"TURN_CREDENTIAL_TTL_SECONDS", "86401"}, {"TURN_IDENTITY_ISSUER", "http://identity.example"}, {"TURN_URLS", "https://example.com"}, {"TURN_ALLOWED_ORIGINS", "*"},
	} {
		t.Run(tc.key+tc.value, func(t *testing.T) {
			t.Setenv(tc.key, tc.value)
			if _, err := loadTURNConfig(); err == nil {
				t.Fatal("invalid configuration accepted")
			}
		})
	}
	cfg, err := loadTURNConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.audience != "viewvee-api" || cfg.scope != "viewvee-api" || cfg.ttl != 24*time.Hour {
		t.Fatal("unexpected defaults")
	}
}

func TestTURNRequiresPremiumWhenEnabled(t *testing.T) {
	owned := false
	s := &turnService{config: turnConfig{secret: strings.Repeat("s", 32), scope: "viewvee-api", ttl: time.Hour, urls: []string{"turns:turn.viewvee.com:443?transport=tcp"}}, now: time.Now, windows: make(map[string]issuanceWindow), verify: func(context.Context, string) (turnIdentity, error) {
		return turnIdentity{"user", []string{"viewvee-api"}}, nil
	}, premium: func(context.Context, string) bool { return owned }}
	request := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/turn/credentials", nil)
		r.Header.Set("Authorization", "Bearer token")
		w := httptest.NewRecorder()
		s.handleCredentials(w, r)
		return w
	}
	if w := request(); w.Code != 403 || !strings.Contains(w.Body.String(), "premium_required") {
		t.Fatalf("free account received TURN credentials: %d", w.Code)
	}
	owned = true
	if w := request(); w.Code != 200 {
		t.Fatalf("premium account rejected: %d", w.Code)
	}
}
