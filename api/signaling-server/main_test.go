package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func testConfig() config {
	return config{
		address:              ":0",
		maxConnections:       20,
		maxConnectionsPerIP:  10,
		maxRooms:             10,
		maxMessagesPerSecond: 100,
		readLimit:            264 * 1024,
		registrationTimeout:  time.Second,
		writeTimeout:         time.Second,
		pingInterval:         time.Hour,
	}
}

func TestValidateRegistration(t *testing.T) {
	validSession := "MDEyMzQ1Njc4OWFiY2RlZg"
	if err := validateRegistration(clientMessage{
		Type: "register", Protocol: 1, Session: validSession, Role: roleTransmitter,
	}); err != nil {
		t.Fatalf("valid registration rejected: %v", err)
	}

	invalid := []clientMessage{
		{Type: "relay", Protocol: 1, Session: validSession, Role: roleTransmitter},
		{Type: "register", Protocol: 2, Session: validSession, Role: roleTransmitter},
		{Type: "register", Protocol: 1, Session: "123456", Role: roleTransmitter},
		{Type: "register", Protocol: 1, Session: validSession, Role: "observer"},
	}
	for _, message := range invalid {
		if err := validateRegistration(message); err == nil {
			t.Fatalf("invalid registration accepted: %+v", message)
		}
	}
}

func TestWebSocketRegistrationAndRelay(t *testing.T) {
	for _, transmitterPath := range []string{"/baby-monitor/ws", "/viewvee/ws"} {
		for _, receiverPath := range []string{"/baby-monitor/ws", "/viewvee/ws"} {
			t.Run(transmitterPath+"->"+receiverPath, func(t *testing.T) {
				testWebSocketRegistrationAndRelay(t, transmitterPath, receiverPath)
			})
		}
	}
}

func testWebSocketRegistrationAndRelay(t *testing.T, transmitterPath, receiverPath string) {
	t.Helper()
	s := newServer(testConfig(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	httpServer := httptest.NewServer(s.routes())
	defer httpServer.Close()
	baseURL := "ws" + strings.TrimPrefix(httpServer.URL, "http")
	url := baseURL + receiverPath
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	transmitter := dialAndRegister(t, ctx, baseURL+transmitterPath, roleTransmitter)
	defer transmitter.CloseNow()
	receiver := dialAndRegister(t, ctx, url, roleReceiver)
	defer receiver.CloseNow()

	receiverReady := readMessage(t, ctx, receiver)
	transmitterReady := readMessage(t, ctx, transmitter)
	if receiverReady.Type != "peer_ready" || transmitterReady.Type != "peer_ready" {
		t.Fatalf("expected peer_ready messages, got %+v and %+v", receiverReady, transmitterReady)
	}
	if receiverReady.Epoch == "" || receiverReady.Epoch != transmitterReady.Epoch {
		t.Fatalf("peers received different epochs: %q and %q", receiverReady.Epoch, transmitterReady.Epoch)
	}

	payload := json.RawMessage(`{"type":"secure","seq":1,"body":"{}","mac":"test"}`)
	if err := wsjson.Write(ctx, transmitter, clientMessage{Type: "relay", Payload: payload}); err != nil {
		t.Fatalf("write relay: %v", err)
	}
	relayed := readMessage(t, ctx, receiver)
	if relayed.Type != "relay" || string(relayed.Payload) != string(payload) {
		t.Fatalf("relay changed payload: %+v", relayed)
	}

	third, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial third client: %v", err)
	}
	defer third.CloseNow()
	if err := wsjson.Write(ctx, third, registration(roleReceiver)); err != nil {
		t.Fatalf("register third client: %v", err)
	}
	rejected := readMessage(t, ctx, third)
	if rejected.Type != "error" || rejected.Code != "room_full" {
		t.Fatalf("expected room_full, got %+v", rejected)
	}

	if err := receiver.Close(websocket.StatusNormalClosure, "test reconnect"); err != nil {
		t.Fatalf("close receiver: %v", err)
	}
	if left := readMessage(t, ctx, transmitter); left.Type != "peer_left" {
		t.Fatalf("expected peer_left, got %+v", left)
	}
	replacement := dialAndRegister(t, ctx, url, roleReceiver)
	defer replacement.CloseNow()
	replacementReady := readMessage(t, ctx, replacement)
	transmitterReady = readMessage(t, ctx, transmitter)
	if replacementReady.Type != "peer_ready" ||
		transmitterReady.Type != "peer_ready" ||
		replacementReady.Epoch == receiverReady.Epoch ||
		replacementReady.Epoch != transmitterReady.Epoch {
		t.Fatalf("replacement peer did not get a fresh shared epoch")
	}
}

func dialAndRegister(t *testing.T, ctx context.Context, url string, clientRole role) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", clientRole, err)
	}
	if err := wsjson.Write(ctx, conn, registration(clientRole)); err != nil {
		conn.CloseNow()
		t.Fatalf("register %s: %v", clientRole, err)
	}
	message := readMessage(t, ctx, conn)
	if message.Type != "registered" {
		conn.CloseNow()
		t.Fatalf("expected registered for %s, got %+v", clientRole, message)
	}
	return conn
}

func registration(clientRole role) clientMessage {
	return clientMessage{
		Type: "register", Protocol: 1,
		Session: "MDEyMzQ1Njc4OWFiY2RlZg", Role: clientRole,
	}
}

func readMessage(t *testing.T, ctx context.Context, conn *websocket.Conn) serverMessage {
	t.Helper()
	var message serverMessage
	if err := wsjson.Read(ctx, conn, &message); err != nil {
		t.Fatalf("read server message: %v", err)
	}
	return message
}
