package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

type turnConfig struct {
	secret, issuer, audience, scope string
	urls, origins                   []string
	ttl                             time.Duration
}

func loadTURNConfig() (turnConfig, error) {
	c := turnConfig{
		secret:   strings.TrimSpace(os.Getenv("TURN_SHARED_SECRET")),
		issuer:   env("TURN_IDENTITY_ISSUER", "https://identity.specterint.com/"),
		audience: env("TURN_IDENTITY_AUDIENCE", "viewvee-api"),
		scope:    env("TURN_REQUIRED_SCOPE", "viewvee-api"),
		urls:     strings.Split(env("TURN_URLS", "turn:turn.viewvee.com:3478?transport=udp,turn:turn.viewvee.com:3478?transport=tcp,turns:turn.viewvee.com:443?transport=tcp"), ","),
	}
	if c.secret == "" {
		return c, nil
	} // Endpoint stays unavailable until configured.
	if len(c.secret) < 32 {
		return c, errors.New("TURN_SHARED_SECRET must contain at least 32 characters")
	}
	seconds, err := strconv.Atoi(env("TURN_CREDENTIAL_TTL_SECONDS", "86400"))
	if err != nil || seconds < 300 || seconds > 86400 {
		return c, errors.New("TURN_CREDENTIAL_TTL_SECONDS must be between 300 and 86400")
	}
	c.ttl = time.Duration(seconds) * time.Second
	issuer, err := url.Parse(c.issuer)
	if err != nil || issuer.Scheme != "https" || issuer.Host == "" || issuer.RawQuery != "" || issuer.Fragment != "" {
		return c, errors.New("TURN_IDENTITY_ISSUER must be an HTTPS issuer URL")
	}
	for i, value := range c.urls {
		value = strings.TrimSpace(value)
		parsed, err := url.Parse(value)
		if err != nil || (parsed.Scheme != "turn" && parsed.Scheme != "turns") || parsed.Opaque == "" || strings.ContainsAny(parsed.Opaque, " /@#") {
			return c, errors.New("TURN_URLS must contain comma-separated turn: or turns: URLs")
		}
		if parsed.RawQuery != "" && parsed.RawQuery != "transport=tcp" && parsed.RawQuery != "transport=udp" {
			return c, errors.New("TURN_URLS contains an unsupported transport")
		}
		c.urls[i] = value
	}
	for _, value := range strings.Split(os.Getenv("TURN_ALLOWED_ORIGINS"), ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		origin, err := url.Parse(value)
		if err != nil || (origin.Scheme != "https" && origin.Scheme != "http") || origin.Host == "" || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" || origin.User != nil {
			return c, errors.New("TURN_ALLOWED_ORIGINS must contain exact origins without paths")
		}
		c.origins = append(c.origins, value)
	}
	return c, nil
}

type turnIdentity struct {
	subject string
	scopes  []string
}
type turnVerifier func(context.Context, string) (turnIdentity, error)
type issuanceWindow struct {
	start time.Time
	count int
}
type turnService struct {
	config  turnConfig
	verify  turnVerifier
	now     func() time.Time
	mu      sync.Mutex
	windows map[string]issuanceWindow
}

func newTURNService(ctx context.Context, c turnConfig) (*turnService, error) {
	if c.secret == "" {
		return nil, nil
	}
	// Keep a persistent context for future JWKS refreshes; bound each HTTP call.
	client := &http.Client{Timeout: 8 * time.Second}
	provider, err := oidc.NewProvider(oidc.ClientContext(ctx, client), c.issuer)
	if err != nil {
		return nil, fmt.Errorf("IdentityServer discovery: %w", err)
	}
	verifier := provider.VerifierContext(oidc.ClientContext(ctx, client), &oidc.Config{
		ClientID:             c.audience,
		SupportedSigningAlgs: []string{oidc.RS256, oidc.RS384, oidc.RS512, oidc.PS256, oidc.PS384, oidc.PS512, oidc.ES256, oidc.ES384, oidc.ES512},
	})
	return &turnService{config: c, now: time.Now, windows: make(map[string]issuanceWindow), verify: func(ctx context.Context, raw string) (turnIdentity, error) {
		token, err := verifier.Verify(ctx, raw)
		if err != nil {
			return turnIdentity{}, err
		}
		var claims struct {
			Scope     json.RawMessage `json:"scope"`
			NotBefore int64           `json:"nbf"`
		}
		if err := token.Claims(&claims); err != nil {
			return turnIdentity{}, err
		}
		if token.Subject == "" || claims.NotBefore > time.Now().Unix() {
			return turnIdentity{}, errors.New("invalid subject or token not yet valid")
		}
		var scopes []string
		var scope string
		if json.Unmarshal(claims.Scope, &scope) == nil {
			scopes = strings.Fields(scope)
		} else if json.Unmarshal(claims.Scope, &scopes) != nil {
			return turnIdentity{}, errors.New("missing access token scope")
		}
		return turnIdentity{subject: token.Subject, scopes: scopes}, nil
	}}, nil
}

func (s *turnService) cors(w http.ResponseWriter, r *http.Request) bool {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Add("Vary", "Origin")
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	// Same-origin browser requests do not need CORS headers.
	if origin == "https://"+r.Host || origin == "http://"+r.Host {
		return true
	}
	if s != nil {
		for _, allowed := range s.config.origins {
			if origin == allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Authorization")
				return true
			}
		}
	}
	writeJSONError(w, http.StatusForbidden, "Origin is not allowed.")
	return false
}
func (s *turnService) handleOptions(w http.ResponseWriter, r *http.Request) {
	if !s.cors(w, r) {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
func (s *turnService) allow(subject string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for key, window := range s.windows {
		if now.Sub(window.start) >= time.Hour {
			delete(s.windows, key)
		}
	}
	window, found := s.windows[subject]
	if !found {
		if len(s.windows) >= 10000 {
			return false
		}
		window.start = now
	}
	if window.count >= 60 {
		return false
	}
	window.count++
	s.windows[subject] = window
	return true
}
func (s *turnService) handleCredentials(w http.ResponseWriter, r *http.Request) {
	if !s.cors(w, r) {
		return
	}
	if s == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "TURN credentials are not configured.")
		return
	}
	auth := strings.Fields(r.Header.Get("Authorization"))
	if len(auth) != 2 || !strings.EqualFold(auth[0], "Bearer") || len(auth[1]) > 16384 {
		w.Header().Set("WWW-Authenticate", "Bearer")
		writeJSONError(w, http.StatusUnauthorized, "A valid access token is required.")
		return
	}
	identity, err := s.verify(r.Context(), auth[1])
	if err != nil || identity.subject == "" {
		w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
		writeJSONError(w, http.StatusUnauthorized, "A valid access token is required.")
		return
	}
	permitted := false
	for _, scope := range identity.scopes {
		if scope == s.config.scope {
			permitted = true
			break
		}
	}
	if !permitted {
		writeJSONError(w, http.StatusForbidden, "The access token does not authorize TURN.")
		return
	}
	if !s.allow(identity.subject) {
		w.Header().Set("Retry-After", "3600")
		writeJSONError(w, http.StatusTooManyRequests, "Too many credential requests.")
		return
	}
	expires := s.now().Add(s.config.ttl).Truncate(time.Second)
	// Avoid putting IdentityServer's subject/PII into relay logs, or accepting ':' in it.
	user := sha256.Sum256([]byte(identity.subject))
	username := strconv.FormatInt(expires.Unix(), 10) + ":" + hex.EncodeToString(user[:16])
	mac := hmac.New(sha1.New, []byte(s.config.secret)) // Coturn TURN REST requires HMAC-SHA1.
	_, _ = mac.Write([]byte(username))
	writeJSON(w, http.StatusOK, struct {
		URLs       []string  `json:"urls"`
		Username   string    `json:"username"`
		Credential string    `json:"credential"`
		ExpiresAt  time.Time `json:"expiresAt"`
	}{s.config.urls, username, base64.StdEncoding.EncodeToString(mac.Sum(nil)), expires})
}
