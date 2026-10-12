package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

const protocolVersion = 1

type config struct {
	address              string
	allowedOrigins       []string
	trustProxyHeaders    bool
	maxConnections       int
	maxConnectionsPerIP  int
	maxRooms             int
	maxMessagesPerSecond int
	readLimit            int64
	registrationTimeout  time.Duration
	writeTimeout         time.Duration
	pingInterval         time.Duration
}

func loadConfig() (config, error) {
	c := config{
		address:              envString("ADDRESS", ":8080"),
		allowedOrigins:       splitNonEmpty(os.Getenv("ALLOWED_ORIGINS")),
		trustProxyHeaders:    envBool("TRUST_PROXY_HEADERS", false),
		maxConnections:       envInt("MAX_CONNECTIONS", 10_000),
		maxConnectionsPerIP:  envInt("MAX_CONNECTIONS_PER_IP", 20),
		maxRooms:             envInt("MAX_ROOMS", 5_000),
		maxMessagesPerSecond: envInt("MAX_MESSAGES_PER_SECOND", 100),
		readLimit:            int64(envInt("READ_LIMIT_BYTES", 264*1024)),
		registrationTimeout:  envDuration("REGISTRATION_TIMEOUT", 10*time.Second),
		writeTimeout:         envDuration("WRITE_TIMEOUT", 5*time.Second),
		pingInterval:         envDuration("PING_INTERVAL", 20*time.Second),
	}
	if c.maxConnections < 1 || c.maxConnectionsPerIP < 1 || c.maxRooms < 1 || c.maxMessagesPerSecond < 1 || c.readLimit < 1024 {
		return config{}, errors.New("connection, room, and read limits must be positive")
	}
	if c.registrationTimeout <= 0 || c.writeTimeout <= 0 || c.pingInterval <= 0 {
		return config{}, errors.New("timeouts must be positive")
	}
	return c, nil
}

type role string

const (
	roleTransmitter role = "transmitter"
	roleReceiver    role = "receiver"
)

type client struct {
	conn         *websocket.Conn
	role         role
	session      string
	writeTimeout time.Duration
	writeMu      sync.Mutex
	rateMu       sync.Mutex
	rateWindow   time.Time
	rateCount    int
}

func (c *client) allowMessage(maxPerSecond int) bool {
	c.rateMu.Lock()
	defer c.rateMu.Unlock()
	now := time.Now()
	if c.rateWindow.IsZero() || now.Sub(c.rateWindow) >= time.Second {
		c.rateWindow = now
		c.rateCount = 0
	}
	c.rateCount++
	return c.rateCount <= maxPerSecond
}

func (c *client) send(message serverMessage) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), c.writeTimeout)
	defer cancel()
	return wsjson.Write(ctx, c.conn, message)
}

type room struct {
	transmitter *client
	receiver    *client
}

type hub struct {
	mu       sync.Mutex
	rooms    map[string]*room
	maxRooms int
}

func newHub(maxRooms int) *hub {
	return &hub{rooms: make(map[string]*room), maxRooms: maxRooms}
}

type protocolError struct {
	code    string
	message string
}

func (e *protocolError) Error() string { return e.code + ": " + e.message }

func (h *hub) register(c *client) (peer *client, epoch string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	r := h.rooms[c.session]
	if c.role == roleTransmitter {
		if r != nil {
			return nil, "", &protocolError{"session_exists", "This session is already active."}
		}
		if len(h.rooms) >= h.maxRooms {
			return nil, "", &protocolError{"capacity", "The signaling service is at capacity."}
		}
		h.rooms[c.session] = &room{transmitter: c}
		return nil, "", nil
	}

	if r == nil || r.transmitter == nil {
		return nil, "", &protocolError{"room_not_found", "The baby device is not waiting for a parent."}
	}
	if r.receiver != nil {
		return nil, "", &protocolError{"room_full", "A parent is already connected to this baby device."}
	}
	r.receiver = c
	epoch, err = randomEpoch()
	if err != nil {
		r.receiver = nil
		return nil, "", err
	}
	return r.transmitter, epoch, nil
}

func (h *hub) peer(c *client) *client {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rooms[c.session]
	if r == nil {
		return nil
	}
	if c.role == roleTransmitter && r.transmitter == c {
		return r.receiver
	}
	if c.role == roleReceiver && r.receiver == c {
		return r.transmitter
	}
	return nil
}

func (h *hub) unregister(c *client) (peer *client, closePeer bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rooms[c.session]
	if r == nil {
		return nil, false
	}
	if c.role == roleTransmitter && r.transmitter == c {
		peer = r.receiver
		delete(h.rooms, c.session)
		return peer, peer != nil
	}
	if c.role == roleReceiver && r.receiver == c {
		r.receiver = nil
		return r.transmitter, false
	}
	return nil, false
}

type connectionLimiter struct {
	mu       sync.Mutex
	total    int
	byIP     map[string]int
	maxTotal int
	maxPerIP int
}

func newConnectionLimiter(maxTotal, maxPerIP int) *connectionLimiter {
	return &connectionLimiter{
		byIP: make(map[string]int), maxTotal: maxTotal, maxPerIP: maxPerIP,
	}
}

func (l *connectionLimiter) acquire(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.total >= l.maxTotal || l.byIP[ip] >= l.maxPerIP {
		return false
	}
	l.total++
	l.byIP[ip]++
	return true
}

func (l *connectionLimiter) release(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.total > 0 {
		l.total--
	}
	if l.byIP[ip] <= 1 {
		delete(l.byIP, ip)
	} else {
		l.byIP[ip]--
	}
}

type server struct {
	config  config
	hub     *hub
	limiter *connectionLimiter
	logger  *slog.Logger
}

func newServer(c config, logger *slog.Logger) *server {
	return &server{
		config:  c,
		hub:     newHub(c.maxRooms),
		limiter: newConnectionLimiter(c.maxConnections, c.maxConnectionsPerIP),
		logger:  logger,
	}
}

type clientMessage struct {
	Type     string          `json:"type"`
	Protocol int             `json:"protocol,omitempty"`
	Session  string          `json:"session,omitempty"`
	Role     role            `json:"role,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
}

type serverMessage struct {
	Type    string          `json:"type"`
	Code    string          `json:"code,omitempty"`
	Message string          `json:"message,omitempty"`
	Epoch   string          `json:"epoch,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /baby-monitor/ws", s.handleWebSocket)
	mux.HandleFunc("GET /viewvee/ws", s.handleWebSocket)
	return securityHeaders(mux)
}

func (s *server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	if !s.limiter.acquire(ip) {
		http.Error(w, "connection limit exceeded", http.StatusTooManyRequests)
		return
	}
	defer s.limiter.release(ip)

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		OriginPatterns:  s.config.allowedOrigins,
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		s.logger.Warn("websocket upgrade rejected", "error", err)
		return
	}
	conn.SetReadLimit(s.config.readLimit)
	defer conn.CloseNow()

	registrationContext, cancelRegistration := context.WithTimeout(r.Context(), s.config.registrationTimeout)
	var registration clientMessage
	err = wsjson.Read(registrationContext, conn, &registration)
	cancelRegistration()
	if err != nil {
		_ = conn.Close(websocket.StatusPolicyViolation, "registration required")
		return
	}
	if err = validateRegistration(registration); err != nil {
		s.sendProtocolError(conn, err)
		_ = conn.Close(websocket.StatusPolicyViolation, "invalid registration")
		return
	}

	c := &client{
		conn: conn, role: registration.Role, session: registration.Session,
		writeTimeout: s.config.writeTimeout,
	}
	peer, epoch, err := s.hub.register(c)
	if err != nil {
		s.sendProtocolError(conn, err)
		_ = conn.Close(websocket.StatusPolicyViolation, "registration rejected")
		return
	}
	defer s.disconnect(c)

	if err := c.send(serverMessage{Type: "registered"}); err != nil {
		return
	}
	if peer != nil {
		ready := serverMessage{Type: "peer_ready", Epoch: epoch}
		// The newcomer must install its epoch before the existing transmitter
		// can react and send an offer.
		if err := c.send(ready); err != nil {
			return
		}
		if err := peer.send(ready); err != nil {
			return
		}
	}

	s.logger.Info("signaling client registered", "role", c.role)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go s.keepAlive(ctx, conn)

	for {
		var message clientMessage
		if err := wsjson.Read(ctx, conn, &message); err != nil {
			return
		}
		if message.Type != "relay" || !validRelayPayload(message.Payload) {
			s.sendProtocolError(conn, &protocolError{"invalid_message", "Only bounded relay messages are accepted after registration."})
			_ = conn.Close(websocket.StatusPolicyViolation, "invalid message")
			return
		}
		if !c.allowMessage(s.config.maxMessagesPerSecond) {
			s.sendProtocolError(conn, &protocolError{"rate_limit", "The signaling message rate limit was exceeded."})
			_ = conn.Close(websocket.StatusPolicyViolation, "rate limit exceeded")
			return
		}
		peer := s.hub.peer(c)
		if peer == nil {
			s.sendProtocolError(conn, &protocolError{"peer_unavailable", "The remote peer is not connected."})
			continue
		}
		if err := peer.send(serverMessage{Type: "relay", Payload: message.Payload}); err != nil {
			peer.conn.CloseNow()
			if c.role == roleReceiver {
				return
			}
		}
	}
}

func (s *server) keepAlive(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(s.config.pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pingContext, cancel := context.WithTimeout(ctx, s.config.writeTimeout)
			err := conn.Ping(pingContext)
			cancel()
			if err != nil {
				_ = conn.Close(websocket.StatusGoingAway, "keepalive timeout")
				return
			}
		}
	}
}

func (s *server) disconnect(c *client) {
	peer, closePeer := s.hub.unregister(c)
	if peer == nil {
		return
	}
	_ = peer.send(serverMessage{Type: "peer_left"})
	if closePeer {
		_ = peer.conn.Close(websocket.StatusGoingAway, "transmitter disconnected")
	}
}

func (s *server) sendProtocolError(conn *websocket.Conn, err error) {
	code, message := "server_error", "The signaling request failed."
	var protocolErr *protocolError
	if errors.As(err, &protocolErr) {
		code, message = protocolErr.code, protocolErr.message
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.config.writeTimeout)
	defer cancel()
	_ = wsjson.Write(ctx, conn, serverMessage{Type: "error", Code: code, Message: message})
}

func (s *server) clientIP(r *http.Request) string {
	if s.config.trustProxyHeaders {
		if forwarded := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-For"), ",")[0]); net.ParseIP(forwarded) != nil {
			return forwarded
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func validateRegistration(message clientMessage) error {
	if message.Type != "register" || message.Protocol != protocolVersion {
		return &protocolError{"unsupported_protocol", "A supported registration message is required."}
	}
	if message.Role != roleTransmitter && message.Role != roleReceiver {
		return &protocolError{"invalid_role", "Role must be transmitter or receiver."}
	}
	decoded, err := base64.RawURLEncoding.DecodeString(message.Session)
	if err != nil || len(decoded) != 16 || len(message.Session) != 22 {
		return &protocolError{"invalid_session", "Session must be a 128-bit base64url identifier."}
	}
	return nil
}

func validRelayPayload(payload json.RawMessage) bool {
	if len(payload) == 0 || len(payload) > 256*1024 {
		return false
	}
	var value map[string]json.RawMessage
	return json.Unmarshal(payload, &value) == nil && value != nil
}

func randomEpoch() (string, error) {
	bytes := make([]byte, 18)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate session epoch: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func main() {
	c, err := loadConfig()
	if err != nil {
		panic(err)
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	s := newServer(c, logger)
	httpServer := &http.Server{
		Addr:              c.address,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	shutdownContext, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdownContext.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(ctx); err != nil {
			logger.Error("graceful shutdown failed", "error", err)
		}
	}()

	logger.Info("signaling server listening", "address", c.address)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("signaling server stopped", "error", err)
		os.Exit(1)
	}
}

func envString(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envBool(name string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envDuration(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func splitNonEmpty(value string) []string {
	var result []string
	for _, part := range strings.Split(value, ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}
