package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Identity owns account data. Relay only the caller's bearer credential to its
// fixed self-service endpoint; never accept a user id or administrative token.
func handleAccountDeletion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	authorization := strings.Fields(r.Header.Get("Authorization"))
	if len(authorization) != 2 || !strings.EqualFold(authorization[0], "Bearer") || len(authorization[1]) > 16384 {
		writeJSONError(w, 401, "Sign in again before deleting your account.")
		return
	}
	var request struct {
		Confirmed              bool   `json:"confirmed"`
		AppleAuthorizationCode string `json:"appleAuthorizationCode"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if json.NewDecoder(r.Body).Decode(&request) != nil || !request.Confirmed {
		writeJSONError(w, 400, "Confirmation is required.")
		return
	}
	endpoint, err := url.Parse(env("IDENTITY_ACCOUNT_DELETE_URL", "https://identity.specterint.com/api/viewvee/account"))
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" || endpoint.User != nil {
		writeJSONError(w, 503, "Account deletion unavailable.")
		return
	}
	data, _ := json.Marshal(request)
	upstream, _ := http.NewRequestWithContext(r.Context(), "DELETE", endpoint.String(), bytes.NewReader(data))
	upstream.Header.Set("Authorization", "Bearer "+authorization[1])
	upstream.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(upstream)
	if err != nil {
		writeJSONError(w, 503, "Account deletion unavailable. Please retry.")
		return
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case 200, 204:
		w.WriteHeader(http.StatusNoContent)
	case 401, 403:
		writeJSONError(w, 401, "Sign in again before deleting your account.")
	case 409:
		writeJSONError(w, 409, "apple_reauthorization_required")
	default:
		io.Copy(io.Discard, io.LimitReader(response.Body, 16384))
		writeJSONError(w, 503, "Account deletion unavailable. Please retry.")
	}
}
