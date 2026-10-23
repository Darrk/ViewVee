package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func appleFixture(t *testing.T) (*purchaseVerifier, func(appleTransaction) string) {
	t.Helper()
	now := time.Now()
	key := func() *ecdsa.PrivateKey {
		k, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		return k
	}
	rootKey, intermediateKey, leafKey := key(), key(), key()
	template := func(id int64) *x509.Certificate {
		return &x509.Certificate{SerialNumber: big.NewInt(id), Subject: pkix.Name{CommonName: "test"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature}
	}
	root := template(1)
	root.IsCA = true
	root.KeyUsage |= x509.KeyUsageCertSign
	makeCert := func(c, p *x509.Certificate, k, pk *ecdsa.PrivateKey) *x509.Certificate {
		der, e := x509.CreateCertificate(rand.Reader, c, p, &k.PublicKey, pk)
		if e != nil {
			t.Fatal(e)
		}
		cert, e := x509.ParseCertificate(der)
		if e != nil {
			t.Fatal(e)
		}
		return cert
	}
	root = makeCert(root, root, rootKey, rootKey)
	inter := template(2)
	inter.IsCA = true
	inter.KeyUsage |= x509.KeyUsageCertSign
	inter.ExtraExtensions = []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}, Value: []byte{5, 0}}}
	inter = makeCert(inter, root, intermediateKey, rootKey)
	leaf := template(3)
	leaf.ExtraExtensions = []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}, Value: []byte{5, 0}}}
	leaf = makeCert(leaf, inter, leafKey, intermediateKey)
	v := newPurchaseVerifier()
	v.roots = x509.NewCertPool()
	v.roots.AddCert(root)
	v.issuer = "issuer"
	v.keyID = "key"
	der, _ := x509.MarshalPKCS8PrivateKey(rootKey)
	v.keyFile = filepath.Join(t.TempDir(), "key.p8")
	os.WriteFile(v.keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600)
	sign := func(payload appleTransaction) string {
		header, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": []string{base64.StdEncoding.EncodeToString(leaf.Raw), base64.StdEncoding.EncodeToString(inter.Raw)}})
		data, _ := json.Marshal(payload)
		unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(data)
		digest := sha256.Sum256([]byte(unsigned))
		r, s, _ := ecdsa.Sign(rand.Reader, leafKey, digest[:])
		sig := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
		return unsigned + "." + base64.RawURLEncoding.EncodeToString(sig)
	}
	return v, sign
}
func TestAppleVerification(t *testing.T) {
	v, sign := appleFixture(t)
	transaction := appleTransaction{TransactionID: "42", ProductID: v.product, BundleID: v.bundle, Environment: "Production", Type: "Non-Consumable", SignedDate: time.Now().UnixMilli()}
	current := transaction
	v.client = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.String() != "https://api.storekit.apple.com/inApps/v1/transactions/42" || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			t.Fatalf("unexpected request %s", r.URL)
		}
		data, _ := json.Marshal(map[string]string{"signedTransactionInfo": sign(current)})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(data))}, nil
	})}
	proof := purchaseProof{Platform: "apple", ProductID: v.product, TransactionID: "42", VerificationData: sign(transaction)}
	active, err := v.verifyApple(context.Background(), proof)
	if err != nil || !active {
		t.Fatalf("valid transaction rejected: %v", err)
	}
	current.RevocationDate = time.Now().UnixMilli()
	active, err = v.verifyApple(context.Background(), proof)
	if err != nil || active {
		t.Fatalf("refund not recognized: active=%v err=%v", active, err)
	}
	transaction.BundleID = "other.app"
	proof.VerificationData = sign(transaction)
	if _, err = v.verifyApple(context.Background(), proof); err == nil {
		t.Fatal("wrong bundle accepted")
	}
	transaction.BundleID = v.bundle
	transaction.ProductID = "other.product"
	proof.VerificationData = sign(transaction)
	if _, err = v.verifyApple(context.Background(), proof); err == nil {
		t.Fatal("wrong product accepted")
	}
	transaction.ProductID = v.product
	transaction.Environment = "Sandbox"
	proof.VerificationData = sign(transaction)
	v.environment = "Production"
	if _, err = v.verifyApple(context.Background(), proof); err == nil {
		t.Fatal("sandbox accepted by production-only endpoint")
	}
	proof.VerificationData = sign(current) + "tampered"
	if _, err = v.verifyApple(context.Background(), proof); err == nil {
		t.Fatal("tampered signature accepted")
	}
}
func TestPurchaseEndpointRejectsMissingAndUntrustedProof(t *testing.T) {
	v := newPurchaseVerifier()
	for _, body := range []string{`{}`, `{"platform":"apple","productId":"wrong","verificationData":"token"}`, `{"platform":"apple","productId":"premium","verificationData":"not-a-signed-receipt"}`} {
		response := httptest.NewRecorder()
		v.handle(response, httptest.NewRequest("POST", "/api/purchases/verify", strings.NewReader(body)))
		if response.Code == 200 {
			t.Fatalf("invalid proof accepted: %s", body)
		}
	}
}
func TestAccountDeletionRejectsUnauthenticatedOrUnconfirmedRequests(t *testing.T) {
	for _, auth := range []string{"", "Bearer valid-token"} {
		response := httptest.NewRecorder()
		request := httptest.NewRequest("DELETE", "/api/account", strings.NewReader(`{"confirmed":false,"accountId":999}`))
		request.Header.Set("Authorization", auth)
		handleAccountDeletion(response, request)
		if response.Code != 401 && response.Code != 400 {
			t.Fatalf("unexpected status %d", response.Code)
		}
	}
}

func TestPurchaseIsBoundToFirstAccount(t *testing.T) {
	v, sign := appleFixture(t)
	transaction := appleTransaction{TransactionID: "77", ProductID: v.product, BundleID: v.bundle, Environment: "Production", Type: "Non-Consumable", SignedDate: time.Now().UnixMilli()}
	v.client = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		data, _ := json.Marshal(map[string]string{"signedTransactionInfo": sign(transaction)})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(data))}, nil
	})}
	v.scope = "viewvee-api"
	v.identify = func(_ context.Context, token string) (turnIdentity, error) {
		return turnIdentity{subject: token, scopes: []string{"viewvee-api"}}, nil
	}
	v.store.path = filepath.Join(t.TempDir(), "entitlements.json")
	body, _ := json.Marshal(purchaseProof{Platform: "apple", ProductID: v.product, TransactionID: "77", VerificationData: sign(transaction)})
	call := func(method, path, subject string) *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(method, path, bytes.NewReader(body))
		if subject != "" {
			request.Header.Set("Authorization", "Bearer "+subject)
		}
		if method == "POST" {
			v.handle(response, request)
		} else {
			v.handleEntitlement(response, request)
		}
		return response
	}
	if w := call("POST", "/api/purchases/verify", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"active":true`) {
		t.Fatalf("guest purchase rejected: %d %s", w.Code, w.Body)
	}
	if len(v.store.records) != 0 {
		t.Fatal("guest purchase bound to an account")
	}
	if w := call("POST", "/api/purchases/verify", "alice"); w.Code != 200 || !strings.Contains(w.Body.String(), `"active":true`) {
		t.Fatalf("owner rejected: %d %s", w.Code, w.Body)
	}
	if w := call("POST", "/api/purchases/verify", "alice"); w.Code != 200 {
		t.Fatalf("owner restore rejected: %d", w.Code)
	}
	if w := call("POST", "/api/purchases/verify", "mallory"); w.Code != 409 {
		t.Fatalf("receipt replay accepted: %d", w.Code)
	}
	if w := call("POST", "/api/purchases/verify", ""); w.Code != 409 {
		t.Fatalf("owned receipt unlocked a guest device: %d", w.Code)
	}
	if w := call("GET", "/api/purchases/entitlement", "alice"); !strings.Contains(w.Body.String(), `"active":true`) {
		t.Fatalf("owner entitlement missing: %s", w.Body)
	}
	if w := call("GET", "/api/purchases/entitlement", "mallory"); !strings.Contains(w.Body.String(), `"active":false`) {
		t.Fatalf("entitlement leaked: %s", w.Body)
	}
	reopened, err := openEntitlementStore(v.store.path)
	if err != nil || len(reopened.forSubject("alice")) != 1 {
		t.Fatalf("store not persisted: %v", err)
	}
	// A refund found during the periodic re-check revokes Premium.
	v.now = func() time.Time { return time.Now().Add(2 * entitlementRecheck) }
	transaction.RevocationDate = time.Now().UnixMilli()
	if v.premium(context.Background(), "alice") {
		t.Fatal("refunded purchase still grants Premium")
	}
}
