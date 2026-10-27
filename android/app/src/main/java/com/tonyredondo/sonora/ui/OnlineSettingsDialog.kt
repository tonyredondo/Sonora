package com.tonyredondo.sonora

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

@Composable
fun OnlineSettingsDialog(model: PlayerModel, dismiss: () -> Unit) {
    val saved by model.graph.online.collectAsStateWithLifecycle()
    var endpoint by remember { mutableStateOf(saved.endpoint) }
    var token by remember { mutableStateOf(saved.token) }
    var language by remember { mutableStateOf(saved.language) }
    var enabled by remember { mutableStateOf(saved.enabled) }
    var working by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    var languages by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    fun input() = OnlineSettings(endpoint, token, language, enabled)
    Dialog(
        { if (!working) dismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.systemBarsPadding().imePadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("Servicios online", style = MaterialTheme.typography.headlineSmall)
                    IconButton(onClick = dismiss, enabled = !working) {
                        Icon(Icons.Rounded.Close, "Listo")
                    }
                }
                LazyColumn(
                    Modifier.weight(1f).padding(horizontal = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    contentPadding = PaddingValues(bottom = 24.dp),
                ) {
                    item {
                        Text(
                            "Sonora usa tu servidor para preparar la traducción y la información de canciones y álbumes. Los resultados guardados funcionan sin conexión.",
                        )
                    }
                    item {
                        OutlinedTextField(
                            endpoint,
                            { endpoint = it },
                            Modifier.fillMaxWidth(),
                            label = { Text("Dirección del servidor") },
                            placeholder = { Text("https://tu-servidor.ts.net") },
                            keyboardOptions =
                                KeyboardOptions(
                                    keyboardType = KeyboardType.Uri,
                                    autoCorrectEnabled = false,
                                ),
                            singleLine = true,
                            enabled = !working,
                        )
                    }
                    item {
                        OutlinedTextField(
                            token,
                            { token = it },
                            Modifier.fillMaxWidth(),
                            label = { Text("Token de acceso") },
                            visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions =
                                KeyboardOptions(
                                    keyboardType = KeyboardType.Password,
                                    autoCorrectEnabled = false,
                                ),
                            singleLine = true,
                            enabled = !working,
                        )
                    }
                    item {
                        Box {
                            OutlinedButton(onClick = { languages = true }, enabled = !working) {
                                Text("Idioma · ${languageName(language)}")
                            }
                            DropdownMenu(languages, { languages = false }) {
                                listOf("es", "en", "fr", "de", "it", "pt").forEach { code ->
                                    DropdownMenuItem(
                                        text = { Text(languageName(code)) },
                                        onClick = {
                                            language = code
                                            languages = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                    item {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text("Preparar toda la cola automáticamente", Modifier.weight(1f))
                            Switch(enabled, { enabled = it }, enabled = !working)
                        }
                    }
                    item {
                        Text(
                            "Las nuevas traducciones y descripciones consumen uso de tu plan de Codex. Cambiar de página reutiliza el contenido guardado.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    result?.let { message -> item { Text(message) } }
                    if (working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedButton(
                                onClick = {
                                    focus.clearFocus()
                                    working = true
                                    result = null
                                    scope.launch {
                                        try {
                                            ProxyClient(input()).check()
                                            result = "Conectado al servidor."
                                        } catch (error: Exception) {
                                            if (error is kotlinx.coroutines.CancellationException)
                                                throw error
                                            result = error.userMessage()
                                        } finally {
                                            working = false
                                        }
                                    }
                                },
                                enabled = !working && endpoint.isNotBlank(),
                            ) {
                                Text("Comprobar")
                            }
                            Button(
                                onClick = {
                                    focus.clearFocus()
                                    working = true
                                    result = null
                                    scope.launch {
                                        try {
                                            model.graph.saveOnline(input())
                                            dismiss()
                                        } catch (error: Exception) {
                                            if (error is kotlinx.coroutines.CancellationException)
                                                throw error
                                            result = error.userMessage()
                                        } finally {
                                            working = false
                                        }
                                    }
                                },
                                enabled = !working,
                            ) {
                                Text("Guardar")
                            }
                        }
                    }
                }
            }
        }
    }
}

fun languageName(code: String): String =
    when (code) {
        "en" -> "English"
        "fr" -> "Français"
        "de" -> "Deutsch"
        "it" -> "Italiano"
        "pt" -> "Português"
        else -> "Español"
    }
