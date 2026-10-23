package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var errPurchaseOwnedElsewhere = errors.New("purchase belongs to another account")

// entitlementRecord binds one store transaction to the account that first
// redeemed it, so a copied receipt or purchase token cannot unlock others.
type entitlementRecord struct {
	Subject    string        `json:"subject"`
	Proof      purchaseProof `json:"proof"`
	Active     bool          `json:"active"`
	VerifiedAt time.Time     `json:"verifiedAt"`
}

// entitlementStore is a small JSON file guarded by a mutex. It suits a single
// API instance with a persistent volume; replace it with a database before
// running several instances.
type entitlementStore struct {
	path    string
	mu      sync.Mutex
	records map[string]entitlementRecord
}

func openEntitlementStore(path string) (*entitlementStore, error) {
	s := &entitlementStore{path: path, records: map[string]entitlementRecord{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.records); err != nil {
		return nil, err
	}
	return s, nil
}

// purchaseKey identifies a transaction independently of who presents it.
func purchaseKey(proof purchaseProof) string {
	if proof.Platform == "apple" {
		return "apple:" + proof.TransactionID
	}
	token := sha256.Sum256([]byte(proof.VerificationData))
	return "google:" + hex.EncodeToString(token[:])
}

// claim stores a verified purchase for subject. A transaction already owned by
// another account is rejected.
func (s *entitlementStore) claim(subject string, proof purchaseProof, active bool, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := purchaseKey(proof)
	if existing, found := s.records[key]; found && existing.Subject != subject {
		return errPurchaseOwnedElsewhere
	}
	s.records[key] = entitlementRecord{Subject: subject, Proof: proof, Active: active, VerifiedAt: now}
	return s.saveLocked()
}

// owned reports whether any account has already redeemed the purchase.
func (s *entitlementStore) owned(proof purchaseProof) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, found := s.records[purchaseKey(proof)]
	return found
}

// forSubject returns the subject's purchases keyed by transaction.
func (s *entitlementStore) forSubject(subject string) map[string]entitlementRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := map[string]entitlementRecord{}
	for key, record := range s.records {
		if record.Subject == subject {
			result[key] = record
		}
	}
	return result
}

func (s *entitlementStore) update(key string, active bool, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	record, found := s.records[key]
	if !found {
		return nil
	}
	record.Active, record.VerifiedAt = active, now
	s.records[key] = record
	return s.saveLocked()
}

func (s *entitlementStore) saveLocked() error {
	if s.path == "" {
		return nil
	}
	data, err := json.Marshal(s.records)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	// Write then rename so a crash never leaves a truncated store behind.
	temp := s.path + ".tmp"
	if err := os.WriteFile(temp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temp, s.path)
}
