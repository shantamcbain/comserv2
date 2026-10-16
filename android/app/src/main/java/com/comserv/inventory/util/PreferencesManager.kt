package com.comserv.inventory.util

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "comserv_settings")

class PreferencesManager(private val context: Context) {

    companion object {
        val KEY_NETWORK_MODE = stringPreferencesKey("network_mode")
        val KEY_SITENAME = stringPreferencesKey("sitename")
        val KEY_PORT = stringPreferencesKey("port")
        val KEY_USERNAME = stringPreferencesKey("username")
        val KEY_SESSION_COOKIE = stringPreferencesKey("session_cookie")

        const val MODE_LAN = "lan"
        const val MODE_ZEROTIER = "zerotier"
        const val DEFAULT_PORT = "4001"
        const val DEFAULT_SITENAME = "CSC"

        /** One network at a time. LAN is .local. ZeroTier is .zero. Never both. */
        fun serverUrl(mode: String, sitename: String, port: String): String {
            val site = sitename.trim().ifEmpty { DEFAULT_SITENAME }
            val host = if (site.equals("CSC", ignoreCase = true)) "workstation" else site.lowercase()
            val zone = if (mode == MODE_ZEROTIER) "zero" else "local"
            val p = port.trim().ifEmpty { DEFAULT_PORT }
            return "http://$host.$zone:$p"
        }
    }

    val networkMode: Flow<String> = context.dataStore.data.map { it[KEY_NETWORK_MODE] ?: MODE_LAN }
    val sitename: Flow<String> = context.dataStore.data.map { it[KEY_SITENAME] ?: DEFAULT_SITENAME }
    val port: Flow<String> = context.dataStore.data.map { it[KEY_PORT] ?: DEFAULT_PORT }
    val username: Flow<String> = context.dataStore.data.map { it[KEY_USERNAME] ?: "" }
    val sessionCookie: Flow<String> = context.dataStore.data.map { it[KEY_SESSION_COOKIE] ?: "" }

    suspend fun saveLogin(mode: String, sitename: String, port: String, username: String, cookie: String) {
        context.dataStore.edit { prefs ->
            prefs[KEY_NETWORK_MODE] = mode
            prefs[KEY_SITENAME] = sitename.trim().ifEmpty { DEFAULT_SITENAME }
            prefs[KEY_PORT] = port.trim().ifEmpty { DEFAULT_PORT }
            prefs[KEY_USERNAME] = username.trim()
            prefs[KEY_SESSION_COOKIE] = cookie
        }
    }

    suspend fun logout() {
        context.dataStore.edit { prefs ->
            prefs[KEY_SESSION_COOKIE] = ""
        }
    }
}
