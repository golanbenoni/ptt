package app.ptt.crypto

import java.util.Optional
import java.util.UUID
import org.signal.libsignal.metadata.certificate.CertificateValidator
import org.signal.libsignal.metadata.certificate.SenderCertificate
import org.signal.libsignal.metadata.certificate.ServerCertificate
import org.signal.libsignal.protocol.ecc.ECKeyPair
import org.signal.libsignal.protocol.ecc.ECPublicKey

/**
 * Local trust root so PR2 tests can exercise SSv2 without a real prekey server.
 * Production issues sender certs from [server/prekey] (PR8).
 */
class TestCertificateAuthority {
    val trustRoot: ECKeyPair = ECKeyPair.generate()
    private val server: ECKeyPair = ECKeyPair.generate()
    val serverCert: ServerCertificate = ServerCertificate(trustRoot.privateKey, 1, server.publicKey)

    fun validator(): CertificateValidator = CertificateValidator(trustRoot.publicKey)

    fun issue(aci: UUID, deviceId: Int, identityPublic: ECPublicKey): SenderCertificate {
        val expiration = System.currentTimeMillis() + 7L * 24 * 3600 * 1000
        return serverCert.issue(
            server.privateKey,
            aci.toString(),
            Optional.empty(),
            deviceId,
            identityPublic,
            expiration,
        )
    }
}
