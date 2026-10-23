package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"golang.org/x/oauth2/google"
)

// Public trust anchor downloaded from Apple's certificate authority repository.
//
//go:embed certs/AppleRootCA-G3.pem
var appleRootPEM []byte

var errInvalidPurchase = errors.New("invalid purchase")

type purchaseProof struct {
	Platform         string `json:"platform"`
	ProductID        string `json:"productId"`
	TransactionID    string `json:"transactionId"`
	VerificationData string `json:"verificationData"`
}
type appleTransaction struct {
	TransactionID  string `json:"transactionId"`
	ProductID      string `json:"productId"`
	BundleID       string `json:"bundleId"`
	Environment    string `json:"environment"`
	Type           string `json:"type"`
	RevocationDate int64  `json:"revocationDate"`
	SignedDate     int64  `json:"signedDate"`
}
type purchaseVerifier struct {
	product, bundle, environment, issuer, keyID, keyFile, googleCredentials string
	roots                                                                   *x509.CertPool
	client                                                                  *http.Client
}

func newPurchaseVerifier() *purchaseVerifier {
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(appleRootPEM)
	return &purchaseVerifier{
		product:     env("PREMIUM_PRODUCT_ID", "viewvee.premium.lifetime"),
		bundle:      env("PURCHASE_BUNDLE_ID", "com.specterint.viewvee"),
		environment: env("APPLE_STORE_ENVIRONMENT", "Both"),
		issuer:      os.Getenv("APPLE_STORE_ISSUER_ID"), keyID: os.Getenv("APPLE_STORE_KEY_ID"),
		keyFile: os.Getenv("APPLE_STORE_PRIVATE_KEY_FILE"), googleCredentials: os.Getenv("GOOGLE_PLAY_CREDENTIALS_FILE"),
		roots: roots, client: &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}
}
func (v *purchaseVerifier) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	var proof purchaseProof
	if json.NewDecoder(r.Body).Decode(&proof) != nil || proof.ProductID != v.product || proof.VerificationData == "" {
		writeJSONError(w, 400, "Invalid purchase proof.")
		return
	}
	var active bool
	var err error
	switch proof.Platform {
	case "apple":
		active, err = v.verifyApple(r.Context(), proof)
	case "google":
		active, err = v.verifyGoogle(r.Context(), proof)
	default:
		err = errInvalidPurchase
	}
	if errors.Is(err, errInvalidPurchase) {
		writeJSONError(w, 422, "Purchase could not be verified.")
		return
	}
	if err != nil {
		writeJSONError(w, 503, "Purchase verification is temporarily unavailable.")
		return
	}
	writeJSON(w, 200, map[string]any{"productId": v.product, "active": active})
}
func (v *purchaseVerifier) decodeApple(raw string) (appleTransaction, error) {
	var transaction appleTransaction
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return transaction, errInvalidPurchase
	}
	var header struct {
		Algorithm string   `json:"alg"`
		Chain     []string `json:"x5c"`
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(data, &header) != nil || header.Algorithm != "ES256" || len(header.Chain) < 2 || len(header.Chain) > 4 {
		return transaction, errInvalidPurchase
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(payload, &transaction) != nil || transaction.SignedDate <= 0 || transaction.SignedDate > time.Now().Add(time.Minute).UnixMilli() {
		return transaction, errInvalidPurchase
	}
	certs := []*x509.Certificate{}
	for _, encoded := range header.Chain {
		der, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return transaction, errInvalidPurchase
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return transaction, errInvalidPurchase
		}
		certs = append(certs, cert)
	}
	intermediates := x509.NewCertPool()
	for _, cert := range certs[1:] {
		intermediates.AddCert(cert)
	}
	// Verify at the signed time: a legitimate lifetime receipt may be years old.
	if _, err := certs[0].Verify(x509.VerifyOptions{Roots: v.roots, Intermediates: intermediates, CurrentTime: time.UnixMilli(transaction.SignedDate), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return transaction, errInvalidPurchase
	}
	hasOID := func(cert *x509.Certificate, oid asn1.ObjectIdentifier) bool {
		for _, extension := range cert.Extensions {
			if extension.Id.Equal(oid) {
				return true
			}
		}
		return false
	}
	if !hasOID(certs[0], asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}) || !hasOID(certs[1], asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}) {
		return transaction, errInvalidPurchase
	}
	key, ok := certs[0].PublicKey.(*ecdsa.PublicKey)
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ok || key.Curve.Params().BitSize != 256 || err != nil || len(signature) != 64 || !ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
		return transaction, errInvalidPurchase
	}
	if transaction.BundleID != v.bundle || transaction.ProductID != v.product || transaction.Type != "Non-Consumable" || transaction.TransactionID == "" {
		return transaction, errInvalidPurchase
	}
	return transaction, nil
}
func (v *purchaseVerifier) verifyApple(ctx context.Context, proof purchaseProof) (bool, error) {
	transaction, err := v.decodeApple(proof.VerificationData)
	if err != nil || transaction.TransactionID != proof.TransactionID {
		return false, errInvalidPurchase
	}
	if transaction.Environment != "Production" && transaction.Environment != "Sandbox" {
		return false, errInvalidPurchase
	}
	// Sandbox must be explicitly enabled on the review/test API deployment.
	if transaction.Environment == "Sandbox" && v.environment != "Sandbox" && v.environment != "Both" {
		return false, errInvalidPurchase
	}
	token, err := v.appleAPIToken()
	if err != nil {
		return false, err
	}
	host := "https://api.storekit.apple.com"
	if transaction.Environment == "Sandbox" {
		host = "https://api.storekit-sandbox.apple.com"
	}
	request, _ := http.NewRequestWithContext(ctx, "GET", host+"/inApps/v1/transactions/"+url.PathEscape(transaction.TransactionID), nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response, err := v.client.Do(request)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode == 404 {
		return false, errInvalidPurchase
	}
	if response.StatusCode != 200 {
		return false, fmt.Errorf("Apple status %d", response.StatusCode)
	}
	var body struct {
		Signed string `json:"signedTransactionInfo"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 32<<10)).Decode(&body) != nil {
		return false, errors.New("invalid Apple response")
	}
	current, err := v.decodeApple(body.Signed)
	if err != nil || current.TransactionID != transaction.TransactionID || current.Environment != transaction.Environment {
		return false, errInvalidPurchase
	}
	return current.RevocationDate == 0, nil
}
func (v *purchaseVerifier) appleAPIToken() (string, error) {
	if v.issuer == "" || v.keyID == "" || v.keyFile == "" {
		return "", errors.New("Apple API credentials missing")
	}
	data, err := os.ReadFile(v.keyFile)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return "", errors.New("invalid Apple key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().BitSize != 256 {
		return "", errors.New("invalid Apple key type")
	}
	now := time.Now().Unix()
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": v.keyID, "typ": "JWT"})
	body, _ := json.Marshal(map[string]any{"iss": v.issuer, "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1", "bid": v.bundle})
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	signature := append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
func (v *purchaseVerifier) verifyGoogle(ctx context.Context, proof purchaseProof) (bool, error) {
	if v.googleCredentials == "" {
		return false, errors.New("Play credentials missing")
	}
	credentials, err := os.ReadFile(v.googleCredentials)
	if err != nil {
		return false, err
	}
	config, err := google.JWTConfigFromJSON(credentials, "https://www.googleapis.com/auth/androidpublisher")
	if err != nil {
		return false, err
	}
	// Bound OAuth token acquisition as well as the publisher API call.
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	token, err := config.TokenSource(ctx).Token()
	if err != nil {
		return false, err
	}
	endpoint := "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" + url.PathEscape(v.bundle) + "/purchases/products/" + url.PathEscape(v.product) + "/tokens/" + url.PathEscape(proof.VerificationData)
	request, _ := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	request.Header.Set("Authorization", "Bearer "+token.AccessToken)
	response, err := v.client.Do(request)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	if response.StatusCode == 404 || response.StatusCode == 410 {
		return false, errInvalidPurchase
	}
	if response.StatusCode != 200 {
		return false, fmt.Errorf("Play status %d", response.StatusCode)
	}
	var body struct {
		PurchaseState *int `json:"purchaseState"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 16<<10)).Decode(&body) != nil || body.PurchaseState == nil {
		return false, errors.New("invalid Play response")
	}
	return *body.PurchaseState == 0, nil
}
