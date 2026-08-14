package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeSender struct {
	err     error
	replyTo string
	subject string
	body    string
}

func (s *fakeSender) Send(_ context.Context, replyTo, subject, body string) error {
	s.replyTo, s.subject, s.body = replyTo, subject, body
	return s.err
}

func TestAccountDeletionRequest(t *testing.T) {
	sender := &fakeSender{}
	handler := newHandler(config{staticDir: "web"}, sender)
	body := `{"accountId":"42","email":"owner@example.com","details":"Delete everything","confirmed":true}`
	request := httptest.NewRequest(http.MethodPost, "/account/delete", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusAccepted {
		t.Fatalf("expected %d, got %d: %s", http.StatusAccepted, response.Code, response.Body.String())
	}
	if sender.replyTo != "owner@example.com" || !strings.Contains(sender.subject, "Account deletion") || !strings.Contains(sender.body, "Account ID: 42") {
		t.Fatalf("unexpected email: subject=%q body=%q", sender.subject, sender.body)
	}
}

func TestDeletionRequestRequiresConfirmation(t *testing.T) {
	sender := &fakeSender{}
	handler := newHandler(config{staticDir: "web"}, sender)
	request := httptest.NewRequest(http.MethodPost, "/account/data-delete", strings.NewReader(`{"accountId":"42"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected %d, got %d", http.StatusBadRequest, response.Code)
	}
}

func TestMailFailureReturnsServiceUnavailable(t *testing.T) {
	sender := &fakeSender{err: errors.New("SMTP unavailable")}
	handler := newHandler(config{staticDir: "web"}, sender)
	request := httptest.NewRequest(http.MethodPost, "/account/delete", strings.NewReader(`{"accountId":"42","email":"owner@example.com","confirmed":true}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected %d, got %d", http.StatusServiceUnavailable, response.Code)
	}
}

func TestDeletionPageUsesCleanRoute(t *testing.T) {
	handler := newHandler(config{staticDir: "web"}, &fakeSender{})
	request := httptest.NewRequest(http.MethodGet, "/account/delete?accountId=42", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "Delete your account") {
		t.Fatalf("unexpected response %d: %s", response.Code, response.Body.String())
	}
}
