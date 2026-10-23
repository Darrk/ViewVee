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
	for _, body := range []string{`{}`, `{"platform":"apple","productId":"wrong","verificationData":"token"}`, `{"platform":"apple","productId":"viewvee.premium.lifetime","verificationData":"not-a-signed-receipt"}`} {
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
