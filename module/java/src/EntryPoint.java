package es.chiteroman.playintegrityfix;

import android.os.Build;
import android.util.Log;

import java.lang.reflect.Field;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.KeyStoreSpi;
import java.security.Provider;
import java.security.Security;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.Map;

/**
 * Loaded by the Zygisk module into GMS processes (com.google.android.gms*).
 * Hooks the AndroidKeyStore provider to intercept hardware attestation and
 * force a software-level attestation instead, which does not expose the
 * real bootloader lock state from the TEE.
 *
 * Combined with Build field spoofing (done natively) and a certified
 * fingerprint with DEVICE_INITIAL_SDK_INT < 33, this gives the best
 * chance of passing DEVICE_INTEGRITY on standard evaluation.
 */
public final class EntryPoint {
    private static final String TAG = "Cloak";

    public static void init(String json) {
        try {
            spoofProvider();
            Log.d(TAG, "keystore attestation hook installed");
        } catch (Throwable t) {
            Log.e(TAG, "keystore hook failed: " + t.getMessage());
        }
    }

    /**
     * Replace the AndroidKeyStore provider with a wrapper that intercepts
     * engineGetCertificateChain. When DroidGuard asks for the attestation
     * certificate chain, we return null (forcing it to fall back to
     * basic/software attestation) instead of the hardware chain that
     * would reveal the unlocked bootloader.
     */
    private static void spoofProvider() throws Exception {
        Provider keystoreProvider = Security.getProvider("AndroidKeyStore");
        if (keystoreProvider == null) {
            Log.w(TAG, "AndroidKeyStore provider not found");
            return;
        }

        Provider spoofed = new SpoofProvider(keystoreProvider);
        Security.removeProvider("AndroidKeyStore");
        Security.insertProviderAt(spoofed, 1);
        Log.d(TAG, "AndroidKeyStore provider replaced");
    }

    /**
     * A Provider wrapper that delegates everything to the real AndroidKeyStore
     * but replaces the KeyStore SPI with our hooked version.
     */
    static final class SpoofProvider extends Provider {
        private final Provider real;

        SpoofProvider(Provider real) {
            super(real.getName(), real.getVersion(), real.getInfo());
            this.real = real;
            // Copy all services but replace KeyStore
            putAll(real);
        }

        @Override
        public synchronized Service getService(String type, String algorithm) {
            if ("KeyStore".equals(type) && "AndroidKeyStore".equals(algorithm)) {
                // Return a service that uses our hooked SPI
                Service realService = real.getService(type, algorithm);
                if (realService != null) {
                    return new HookedService(this, type, algorithm,
                            realService.getClassName(), null, null, realService);
                }
            }
            return real.getService(type, algorithm);
        }
    }

    /**
     * A Service that creates a hooked KeyStoreSpi. The hook intercepts
     * engineGetCertificateChain to prevent hardware attestation chains
     * from reaching DroidGuard.
     */
    static final class HookedService extends Provider.Service {
        private final Provider.Service real;

        HookedService(Provider provider, String type, String algorithm,
                      String className, java.util.List<String> aliases,
                      java.util.Map<String, String> attributes,
                      Provider.Service realService) {
            super(provider, type, algorithm, className, aliases, attributes);
            this.real = realService;
        }

        @Override
        public Object newInstance(Object constructorParameter) throws java.security.NoSuchAlgorithmException {
            try {
                Object spi = real.newInstance(constructorParameter);
                if (spi instanceof KeyStoreSpi) {
                    return new HookedKeyStoreSpi((KeyStoreSpi) spi);
                }
                return spi;
            } catch (Exception e) {
                throw new java.security.NoSuchAlgorithmException(e);
            }
        }
    }

    /**
     * KeyStoreSpi wrapper. Intercepts getCertificateChain to strip
     * hardware attestation extension (OID 1.3.6.1.4.1.11129.2.1.17)
     * or return null to force software fallback.
     */
    static final class HookedKeyStoreSpi extends KeyStoreSpi {
        private final KeyStoreSpi delegate;

        HookedKeyStoreSpi(KeyStoreSpi delegate) {
            this.delegate = delegate;
        }

        @Override
        public Certificate[] engineGetCertificateChain(String alias) {
            Certificate[] chain = delegate.engineGetCertificateChain(alias);
            if (chain == null || chain.length == 0) return chain;

            // Check if this chain contains hardware attestation
            // (OID 1.3.6.1.4.1.11129.2.1.17 = Android key attestation)
            try {
                if (chain[0] instanceof X509Certificate) {
                    X509Certificate leaf = (X509Certificate) chain[0];
                    byte[] ext = leaf.getExtensionValue("1.3.6.1.4.1.11129.2.1.17");
                    if (ext != null) {
                        // This is a hardware attestation chain.
                        // Return null so DroidGuard falls back to basic evaluation.
                        Log.d(TAG, "blocked hardware attestation chain for alias: " + alias);
                        return null;
                    }
                }
            } catch (Exception ignored) {
            }
            return chain;
        }

        // --- delegate everything else ---

        @Override
        public java.security.Key engineGetKey(String alias, char[] password)
                throws java.security.NoSuchAlgorithmException, java.security.UnrecoverableKeyException {
            return delegate.engineGetKey(alias, password);
        }

        @Override
        public java.util.Date engineGetCreationDate(String alias) {
            return delegate.engineGetCreationDate(alias);
        }

        @Override
        public void engineSetKeyEntry(String alias, java.security.Key key, char[] password,
                                      Certificate[] chain) throws KeyStoreException {
            delegate.engineSetKeyEntry(alias, key, password, chain);
        }

        @Override
        public void engineSetKeyEntry(String alias, byte[] key, Certificate[] chain)
                throws KeyStoreException {
            delegate.engineSetKeyEntry(alias, key, chain);
        }

        @Override
        public void engineSetCertificateEntry(String alias, Certificate cert)
                throws KeyStoreException {
            delegate.engineSetCertificateEntry(alias, cert);
        }

        @Override
        public void engineDeleteEntry(String alias) throws KeyStoreException {
            delegate.engineDeleteEntry(alias);
        }

        @Override
        public java.util.Enumeration<String> engineAliases() {
            return delegate.engineAliases();
        }

        @Override
        public boolean engineContainsAlias(String alias) {
            return delegate.engineContainsAlias(alias);
        }

        @Override
        public int engineSize() {
            return delegate.engineSize();
        }

        @Override
        public boolean engineIsKeyEntry(String alias) {
            return delegate.engineIsKeyEntry(alias);
        }

        @Override
        public boolean engineIsCertificateEntry(String alias) {
            return delegate.engineIsCertificateEntry(alias);
        }

        @Override
        public String engineGetCertificateAlias(Certificate cert) {
            return delegate.engineGetCertificateAlias(cert);
        }

        @Override
        public void engineStore(java.io.OutputStream stream, char[] password)
                throws java.io.IOException, java.security.NoSuchAlgorithmException,
                java.security.cert.CertificateException {
            delegate.engineStore(stream, password);
        }

        @Override
        public void engineLoad(java.io.InputStream stream, char[] password)
                throws java.io.IOException, java.security.NoSuchAlgorithmException,
                java.security.cert.CertificateException {
            delegate.engineLoad(stream, password);
        }

        @Override
        public Certificate engineGetCertificate(String alias) {
            return delegate.engineGetCertificate(alias);
        }
    }
}
