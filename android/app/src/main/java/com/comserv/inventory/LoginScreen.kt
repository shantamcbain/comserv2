package com.comserv.inventory

import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.comserv.inventory.api.ApiClient
import com.comserv.inventory.util.PreferencesManager
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(onLoggedIn: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { PreferencesManager(context) }

    var mode by remember { mutableStateOf(PreferencesManager.MODE_LAN) }
    var sitename by remember { mutableStateOf(PreferencesManager.DEFAULT_SITENAME) }
    var port by remember { mutableStateOf(PreferencesManager.DEFAULT_PORT) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        prefs.networkMode.collect { mode = it }
    }
    LaunchedEffect(Unit) {
        prefs.sitename.collect { sitename = it }
    }
    LaunchedEffect(Unit) {
        prefs.port.collect { port = it }
    }
    LaunchedEffect(Unit) {
        prefs.username.collect { if (username.isEmpty()) username = it }
    }

    val url = PreferencesManager.serverUrl(mode, sitename, port)
    val scroll = rememberScrollState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .verticalScroll(scroll)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text("Comserv Inventory", style = MaterialTheme.typography.titleLarge)
        Text("Same login as the web app.", style = MaterialTheme.typography.bodySmall)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(
                selected = mode == PreferencesManager.MODE_LAN,
                onClick = { mode = PreferencesManager.MODE_LAN },
                label = { Text("LAN") }
            )
            FilterChip(
                selected = mode == PreferencesManager.MODE_ZEROTIER,
                onClick = { mode = PreferencesManager.MODE_ZEROTIER },
                label = { Text("ZeroTier") }
            )
        }
        Text(url, style = MaterialTheme.typography.bodySmall)

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = sitename,
                onValueChange = { sitename = it },
                label = { Text("Site") },
                modifier = Modifier.weight(1f),
                singleLine = true
            )
            OutlinedTextField(
                value = port,
                onValueChange = { port = it.filter { ch -> ch.isDigit() } },
                label = { Text("Port") },
                modifier = Modifier.width(88.dp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number)
            )
        }
        OutlinedTextField(
            value = username,
            onValueChange = { username = it },
            label = { Text("Username") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("Password") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            visualTransformation = PasswordVisualTransformation()
        )
        Button(
            onClick = {
                if (username.isBlank() || password.isBlank()) {
                    message = "Username and password are required"
                    return@Button
                }
                busy = true
                message = ""
                scope.launch {
                    val client = ApiClient(url, sessionCookie = "", sitename = sitename.trim())
                    val result = client.login(username.trim(), password)
                    busy = false
                    result.fold(
                        onSuccess = { cookie ->
                            prefs.saveLogin(mode, sitename, port, username.trim(), cookie)
                            password = ""
                            Toast.makeText(context, "Logged in", Toast.LENGTH_SHORT).show()
                            onLoggedIn()
                        },
                        onFailure = { err ->
                            message = err.message ?: "Login failed"
                        }
                    )
                }
            },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (busy) "Signing in…" else "Log in")
        }
        if (message.isNotEmpty()) {
            Text(message, color = MaterialTheme.colorScheme.error)
        }
    }
}
