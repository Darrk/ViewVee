package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/mail"
	"net/smtp"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxRequestBody = 16 << 10
const supportEmailAddress = "support@specterint.com"

type config struct {
	addr         string
	staticDir    string
	smtpHost     string
	smtpPort     int
	smtpUsername string
	smtpPassword string
	smtpFrom     string
	smtpFromName string
}

type deletionRequest struct {
	AccountID string `json:"accountId"`
	Email     string `json:"email"`
	Details   string `json:"details"`
	Confirmed bool   `json:"confirmed"`
	Website   string `json:"website"`
}

type mailSender interface {
	Send(context.Context, string, string, string) error
}

type smtpSender struct{ config config }

type rateLimiter struct {
	mu       sync.Mutex
	requests map[string][]time.Time
	now      func() time.Time
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		slog.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	server := &http.Server{
		Addr:              cfg.addr,
		Handler:           newHandler(cfg, smtpSender{config: cfg}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	slog.Info("ViewVee web server listening", "address", cfg.addr, "staticDir", cfg.staticDir)
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		slog.Error("web server stopped", "error", err)
		os.Exit(1)
	}
}

func loadConfig() (config, error) {
	port, err := strconv.Atoi(env("SMTP_PORT", "587"))
	if err != nil || port < 1 || port > 65535 {
		return config{}, errors.New("SMTP_PORT must be a valid TCP port")
	}
	cfg := config{
		addr:         env("HTTP_ADDR", ":8080"),
		staticDir:    env("STATIC_DIR", "web"),
		smtpHost:     env("SMTP_HOST", "email-smtp.eu-central-1.amazonaws.com"),
		smtpPort:     port,
		smtpUsername: os.Getenv("SMTP_USERNAME"),
		smtpPassword: os.Getenv("SMTP_PASSWORD"),
		smtpFrom:     env("SMTP_FROM", "info@specterint.com"),
		smtpFromName: env("SMTP_FROM_NAME", "ViewVee Support"),
	}
	return cfg, nil
}

func env(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func newHandler(cfg config, sender mailSender) http.Handler {
	mux := http.NewServeMux()
	limiter := &rateLimiter{requests: make(map[string][]time.Time), now: time.Now}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
	})
	registerDeletionRoute(mux, cfg, sender, limiter, "/account/delete", "account", "Account deletion request", "account/delete/index.html")
	registerDeletionRoute(mux, cfg, sender, limiter, "/account/data-delete", "data", "Data deletion request", "account/data-delete/index.html")

	files := http.FileServer(http.Dir(cfg.staticDir))
	mux.Handle("/", spaHandler(cfg.staticDir, files))
	return securityHeaders(mux)
}

func registerDeletionRoute(mux *http.ServeMux, cfg config, sender mailSender, limiter *rateLimiter, path, kind, label, page string) {
	servePage := func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, filepath.Join(cfg.staticDir, page))
	}
	mux.HandleFunc("GET "+path, servePage)
	mux.HandleFunc("GET "+path+"/", servePage)
	mux.HandleFunc("POST "+path, func(w http.ResponseWriter, r *http.Request) {
		handleDeletionRequest(w, r, cfg, sender, limiter, kind, label)
	})
	mux.HandleFunc("POST "+path+"/", func(w http.ResponseWriter, r *http.Request) {
		handleDeletionRequest(w, r, cfg, sender, limiter, kind, label)
	})
}

func handleDeletionRequest(w http.ResponseWriter, r *http.Request, cfg config, sender mailSender, limiter *rateLimiter, kind, label string) {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBody)
	defer r.Body.Close()

	var request deletionRequest
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			writeJSONError(w, http.StatusBadRequest, "Invalid request body.")
			return
		}
	} else {
		if err := r.ParseForm(); err != nil {
			writeJSONError(w, http.StatusBadRequest, "Invalid request body.")
			return
		}
		request = deletionRequest{
			AccountID: r.FormValue("accountId"),
			Email:     r.FormValue("email"),
			Details:   r.FormValue("details"),
			Confirmed: r.FormValue("confirmed") == "true" || r.FormValue("confirmed") == "on",
			Website:   r.FormValue("website"),
		}
	}

	request.AccountID = strings.TrimSpace(request.AccountID)
	request.Email = strings.TrimSpace(request.Email)
	request.Details = strings.TrimSpace(request.Details)
	if request.Website != "" { // Honeypot: return success without sending mail.
		writeJSON(w, http.StatusAccepted, map[string]string{"message": "Request received."})
		return
	}
	if request.AccountID == "" || len(request.AccountID) > 255 || len(request.Email) > 320 || len(request.Details) > 2000 || !request.Confirmed || !validEmail(request.Email) {
		writeJSONError(w, http.StatusBadRequest, "Enter your account ID and email address, then confirm the request.")
		return
	}

	ip := clientIP(r)
	if !limiter.Allow(ip) {
		w.Header().Set("Retry-After", "3600")
		writeJSONError(w, http.StatusTooManyRequests, "Too many requests. Please try again later.")
		return
	}

	subject := "[ViewVee] " + label
	body := fmt.Sprintf("New deletion request from the ViewVee website.\n\nRequest type: %s_deletion\nAccount ID: %s\nEmail: %s\nTimestamp (UTC): %s\n", kind, request.AccountID, request.Email, time.Now().UTC().Format(time.RFC3339))
	if request.Details != "" {
		body += "\nAdditional details:\n" + request.Details + "\n"
	}
	body += "\nVerify account ownership before processing this request.\n"

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := sender.Send(ctx, request.Email, subject, body); err != nil {
		slog.Error("failed to send deletion request", "type", kind, "error", err)
		writeJSONError(w, http.StatusServiceUnavailable, "The request could not be sent. Please email support@specterint.com.")
		return
	}
	slog.Info("deletion request submitted", "type", kind)
	writeJSON(w, http.StatusAccepted, map[string]string{"message": "Your request was sent. Support will contact you after verifying account ownership."})
}

func (l *rateLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	cutoff := now.Add(-time.Hour)
	recent := l.requests[key][:0]
	for _, requestTime := range l.requests[key] {
		if requestTime.After(cutoff) {
			recent = append(recent, requestTime)
		}
	}
	if len(recent) >= 3 {
		l.requests[key] = recent
		return false
	}
	l.requests[key] = append(recent, now)
	return true
}

func (s smtpSender) Send(ctx context.Context, replyTo, subject, body string) error {
	cfg := s.config
	if cfg.smtpHost == "" || cfg.smtpUsername == "" || cfg.smtpPassword == "" || cfg.smtpFrom == "" {
		return errors.New("AWS SES SMTP settings are incomplete")
	}
	address := net.JoinHostPort(cfg.smtpHost, strconv.Itoa(cfg.smtpPort))
	dialer := net.Dialer{Timeout: 8 * time.Second}
	var connection net.Conn
	var err error
	if cfg.smtpPort == 465 {
		connection, err = tls.DialWithDialer(&dialer, "tcp", address, &tls.Config{ServerName: cfg.smtpHost, MinVersion: tls.VersionTLS12})
	} else {
		connection, err = dialer.DialContext(ctx, "tcp", address)
	}
	if err != nil {
		return err
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(10 * time.Second))

	client, err := smtp.NewClient(connection, cfg.smtpHost)
	if err != nil {
		return err
	}
	defer client.Close()
	if cfg.smtpPort != 465 {
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(&tls.Config{ServerName: cfg.smtpHost, MinVersion: tls.VersionTLS12}); err != nil {
				return err
			}
		} else if cfg.smtpUsername != "" {
			return errors.New("SMTP server does not support STARTTLS")
		}
	}
	if cfg.smtpUsername != "" {
		if err := client.Auth(smtp.PlainAuth("", cfg.smtpUsername, cfg.smtpPassword, cfg.smtpHost)); err != nil {
			return err
		}
	}
	if err := client.Mail(cfg.smtpFrom); err != nil {
		return err
	}
	if err := client.Rcpt(supportEmailAddress); err != nil {
		return err
	}
	wc, err := client.Data()
	if err != nil {
		return err
	}
	from := (&mail.Address{Name: cfg.smtpFromName, Address: cfg.smtpFrom}).String()
	message := "From: " + from + "\r\nTo: " + supportEmailAddress + "\r\nReply-To: " + replyTo + "\r\nSubject: " + mime.QEncoding.Encode("UTF-8", subject) + "\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n" + body
	if _, err := io.WriteString(wc, message); err != nil {
		return err
	}
	if err := wc.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func validEmail(value string) bool {
	address, err := mail.ParseAddress(value)
	return err == nil && address.Address == value
}

func clientIP(r *http.Request) string {
	if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0]); forwarded != "" {
		return forwarded
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func spaHandler(staticDir string, files http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.NotFound(w, r)
			return
		}
		path := filepath.Clean(strings.TrimPrefix(r.URL.Path, "/"))
		if path == "." {
			path = "index.html"
		}
		if info, err := os.Stat(filepath.Join(staticDir, path)); err == nil && !info.IsDir() {
			files.ServeHTTP(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(staticDir, "index.html"))
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
