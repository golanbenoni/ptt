package app.ptt.crypto

import java.util.UUID
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.signal.libsignal.protocol.IdentityKeyPair

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class CryptoStackPqXdhTest {
    @BeforeAll
    fun requireJni() {
        try {
            IdentityKeyPair.generate()
        } catch (e: UnsatisfiedLinkError) {
            assumeTrue(
                false,
                "libsignal JNI not loaded on this host (linux aarch64 needs scripts/build-libsignal-jni.sh). CI linux-amd64 uses the published jar.",
            )
        } catch (e: ExceptionInInitializerError) {
            assumeTrue(false, "libsignal JNI init failed: ${e.cause ?: e}")
        }
    }

    @Test
    fun twoIdentitiesRoundTripAByteArray() =
        runTest {
            val alice = InMemoryCryptoStack()
            val bob = InMemoryCryptoStack()
            val aliceAci = Aci(UUID.fromString("11111111-1111-4111-8111-111111111111"))
            val bobAci = Aci(UUID.fromString("22222222-2222-4222-8222-222222222222"))
            alice.debugSetAci(aliceAci)
            bob.debugSetAci(bobAci)

            val aliceId = alice.generateIdentity()
            val bobId = bob.generateIdentity()
            assertEquals(32, aliceId.profileKey.size)
            // DJB identity key: type byte 0x05 + 32-byte X25519
            assertEquals(33, bobId.identityKeyPublic.size)
            assertEquals(aliceAci, aliceId.aci)

            alice.replenishPreKeys(100)
            bob.replenishPreKeys(100)

            val bobBundle = bob.localBundle()
            assertEquals(bobAci, bobBundle.aci)
            assertNotNull(bobBundle.kyberPreKey)
            assertTrue(bobBundle.kyberPreKey.isNotEmpty())

            alice.processPreKeyBundle(DeviceId(bobAci), bobBundle)

            val plaintext = "hold-to-talk".toByteArray()
            val ciphertext = alice.encrypt1to1(DeviceId(bobAci), plaintext)
            assertTrue(ciphertext.size > 32, "ciphertext too small")

            val recovered = bob.decrypt1to1(DeviceId(aliceAci), ciphertext)
            assertArrayEquals(plaintext, recovered)

            val reply = "roger".toByteArray()
            val replyCt = bob.encrypt1to1(DeviceId(aliceAci), reply)
            val replyPt = alice.decrypt1to1(DeviceId(bobAci), replyCt)
            assertArrayEquals(reply, replyPt)
        }

    @Test
    fun safetyNumberIsStableAndSymmetricShape() =
        runTest {
            val alice = InMemoryCryptoStack()
            val bob = InMemoryCryptoStack()
            val aliceAci = Aci(UUID.randomUUID())
            val bobAci = Aci(UUID.randomUUID())
            alice.debugSetAci(aliceAci)
            bob.debugSetAci(bobAci)
            alice.generateIdentity()
            bob.generateIdentity()
            alice.replenishPreKeys(10)
            bob.replenishPreKeys(10)
            alice.processPreKeyBundle(DeviceId(bobAci), bob.localBundle())
            bob.processPreKeyBundle(DeviceId(aliceAci), alice.localBundle())

            val a = alice.safetyNumber1to1(bobAci)
            val b = bob.safetyNumber1to1(aliceAci)
            assertEquals(a, b)
            assertTrue(a.all { it.isDigit() }, a)
            assertEquals(60, a.length, a)
        }

    @Test
    fun twoDevicesOnOneAccountHaveIndependentSessionsAndOneAccountFingerprint() =
        runTest {
            val aliceAci = Aci(UUID.fromString("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
            val bobAci = Aci(UUID.fromString("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
            val alicePhone = InMemoryCryptoStack(localDeviceId = 1)
            val aliceTablet = InMemoryCryptoStack(localDeviceId = 2)
            val bob = InMemoryCryptoStack(localDeviceId = 1)
            alicePhone.setAci(aliceAci)
            aliceTablet.setAci(aliceAci)
            bob.setAci(bobAci)
            val phoneIdentity = alicePhone.generateIdentity()
            val tabletIdentity = aliceTablet.generateIdentity()
            val bobIdentity = bob.generateIdentity()
            listOf(alicePhone, aliceTablet, bob).forEach { it.replenishPreKeys(10) }

            bob.processPreKeyBundle(alicePhone.localDevice(), alicePhone.localBundle())
            bob.processPreKeyBundle(aliceTablet.localDevice(), aliceTablet.localBundle())
            alicePhone.processPreKeyBundle(bob.localDevice(), bob.localBundle())
            aliceTablet.processPreKeyBundle(bob.localDevice(), bob.localBundle())

            val phoneMessage = bob.encrypt1to1(alicePhone.localDevice(), "phone".toByteArray())
            val tabletMessage = bob.encrypt1to1(aliceTablet.localDevice(), "tablet".toByteArray())
            assertEquals(
                "phone",
                alicePhone.decrypt1to1(bob.localDevice(), phoneMessage).decodeToString(),
            )
            assertEquals(
                "tablet",
                aliceTablet.decrypt1to1(bob.localDevice(), tabletMessage).decodeToString(),
            )

            val aliceKeys = listOf(phoneIdentity.identityKeyPublic, tabletIdentity.identityKeyPublic)
            val fromAlice =
                alicePhone.safetyNumberAccount(
                    localDeviceIdentityKeys = aliceKeys,
                    peer = bobAci,
                    peerDeviceIdentityKeys = listOf(bobIdentity.identityKeyPublic),
                )
            val fromBob =
                bob.safetyNumberAccount(
                    localDeviceIdentityKeys = listOf(bobIdentity.identityKeyPublic),
                    peer = aliceAci,
                    peerDeviceIdentityKeys = aliceKeys.reversed(),
                )
            assertEquals(fromAlice, fromBob)
            assertEquals(71, fromAlice.length) // 60 digits grouped as 12 groups of five.
        }

}
