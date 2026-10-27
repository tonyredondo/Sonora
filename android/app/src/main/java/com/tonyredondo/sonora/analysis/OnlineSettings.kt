package com.tonyredondo.sonora

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

class OnlineSettings(
    val endpoint: String = "",
    val token: String = "",
    val language: String = "es",
    val enabled: Boolean = true,
) {
    fun sameTransport(other: OnlineSettings): Boolean =
        endpoint.trim().trimEnd('/') == other.endpoint.trim().trimEnd('/') &&
            token == other.token &&
            enabled == other.enabled

    override fun toString(): String =
        "OnlineSettings(language=$language, enabled=$enabled, token=[redacted])"

    fun baseUrl(): HttpUrl? {
        if (endpoint.isBlank()) return null
        val url = (endpoint.trim().trimEnd('/') + "/").toHttpUrlOrNull()
        require(
            url != null &&
                url.username.isEmpty() &&
                url.password.isEmpty() &&
                url.query == null &&
                url.fragment == null,
        ) {
            "Introduce una dirección HTTP o HTTPS válida del servidor, sin contraseña ni parámetros."
        }
        return url
    }

    fun validate() {
        baseUrl()
        require(language in listOf("es", "en", "fr", "de", "it", "pt")) {
            "El idioma elegido no está disponible."
        }
        require(token.length <= 4096 && token.none { it.isISOControl() }) {
            "El token del servidor no es válido."
        }
    }
}

/** Only the device Keystore can decrypt the saved token; it is excluded from backups. */
class OnlineSettingsStore(context: Context) {
    private val preferences = context.getSharedPreferences("sonora_online", Context.MODE_PRIVATE)

    fun read(): OnlineSettings {
        val encrypted = preferences.getString("token", null)
        val token =
            if (encrypted == null) ""
            else {
                val bytes = Base64.decode(encrypted, Base64.NO_WRAP)
                require(bytes.size > 12) {
                    "La conexión guardada no se puede leer. Vuelve a guardar el token."
                }
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    key(false),
                    GCMParameterSpec(128, bytes.copyOfRange(0, 12)),
                )
                String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
            }
        return OnlineSettings(
                preferences.getString("endpoint", "").orEmpty(),
                token,
                preferences.getString("language", "es").orEmpty(),
                preferences.getBoolean("enabled", true),
            )
            .also { it.validate() }
    }

    fun write(value: OnlineSettings) {
        value.validate()
        val encrypted =
            if (value.token.isBlank()) null
            else {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key(true))
                Base64.encodeToString(
                    cipher.iv + cipher.doFinal(value.token.toByteArray(Charsets.UTF_8)),
                    Base64.NO_WRAP,
                )
            }
        check(
            preferences
                .edit()
                .putString("endpoint", value.endpoint.trim())
                .putString("token", encrypted)
                .putString("language", value.language)
                .putBoolean("enabled", value.enabled)
                .commit(),
        ) {
            "No se pudo guardar la conexión."
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("sonora.proxy.token.v1", null) as? SecretKey)?.let {
            return it
        }
        check(create) {
            "El dispositivo no puede recuperar el token guardado. Vuelve a guardarlo en Ajustes."
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                        "sonora.proxy.token.v1",
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }
}

/**
 * A language change may finish and cache its response; changing transport releases network
 * capacity.
 */
internal suspend fun <T> withCurrentTransport(
    state: StateFlow<OnlineSettings>,
    settings: OnlineSettings,
    operation: suspend () -> T,
): T = coroutineScope {
    if (!state.value.sameTransport(settings)) throw ProxyFailure("connection_changed")
    val call = async { operation() }
    val monitor = launch {
        state.first { !it.sameTransport(settings) }
        call.cancel()
    }
    try {
        call.await()
    } catch (cancelled: CancellationException) {
        currentCoroutineContext().ensureActive()
        if (!state.value.sameTransport(settings)) throw ProxyFailure("connection_changed")
        throw cancelled
    } finally {
        monitor.cancel()
    }
}
