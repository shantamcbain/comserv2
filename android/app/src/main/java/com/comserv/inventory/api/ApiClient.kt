package com.comserv.inventory.api

import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.comserv.inventory.model.ApiError
import com.comserv.inventory.model.ApiResponse
import com.comserv.inventory.model.InventoryItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException

class ApiClient(
    private val baseUrl: String,
    private val apiToken: String = "",
    private val sessionCookie: String = "",
    private val sitename: String = ""
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
        .readTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .writeTimeout(30, java.util.concurrent.TimeUnit.SECONDS)
        .build()
    private val gson = Gson()
    private val JSON = "application/json; charset=utf-8".toMediaType()

    /**
     * Upload a photo to the server. Returns the NFS path on success.
     */
    suspend fun uploadPhoto(file: File): Result<String> = withContext(Dispatchers.IO) {
        try {
            val requestBody = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                    "photo",
                    file.name,
                    file.asRequestBody("image/jpeg".toMediaType())
                )
                .build()

            val request = buildRequest("api/inventory/photo/upload")
                .post(requestBody)
                .build()

            val response = client.newCall(request).execute()
            val body = response.body?.string() ?: ""
            Log.d("ApiClient", "Upload response: $body")

            if (response.isSuccessful) {
                val uploadResp = gson.fromJson(body, ApiResponse::class.java)
                if (uploadResp.success && uploadResp.path != null) {
                    Result.success(uploadResp.path)
                } else {
                    Result.failure(IOException(uploadResp.error ?: "Upload failed"))
                }
            } else {
                Result.failure(IOException("Upload failed: ${response.code} $body"))
            }
        } catch (e: Exception) {
            Log.e("ApiClient", "Photo upload error", e)
            Result.failure(e)
        }
    }

    /**
     * Create a new inventory item.
     */
    suspend fun createItem(item: InventoryItem): Result<InventoryItem> = withContext(Dispatchers.IO) {
        try {
            val json = gson.toJson(item.toCreateJson())
            val requestBody = json.toRequestBody(JSON)

            val request = buildRequest("api/inventory/item/create")
                .post(requestBody)
                .build()

            val response = client.newCall(request).execute()
            val body = response.body?.string() ?: ""
            Log.d("ApiClient", "Create item response: $body")

            if (response.isSuccessful) {
                val apiResp = gson.fromJson(body, ApiResponse::class.java)
                if (apiResp.success && apiResp.item != null) {
                    Result.success(apiResp.item)
                } else {
                    Result.failure(IOException(apiResp.error ?: "Unknown error"))
                }
            } else {
                val errorResp = gson.fromJson(body, ApiError::class.java)
                Result.failure(IOException(errorResp.error.ifEmpty { "HTTP ${response.code}" }))
            }
        } catch (e: Exception) {
            Log.e("ApiClient", "Create item error", e)
            Result.failure(e)
        }
    }

    /**
     * Fetch all inventory items (for barcode lookup).
     */
    suspend fun fetchItems(): Result<List<InventoryItem>> = withContext(Dispatchers.IO) {
        try {
            val request = buildRequest("api/inventory/items")
                .get()
                .build()

            val response = client.newCall(request).execute()
            val body = response.body?.string() ?: ""

            if (response.isSuccessful) {
                val apiResp = gson.fromJson(body, ApiResponse::class.java)
                val items = apiResp.items ?: emptyList()
                Result.success(items)
            } else {
                Result.failure(IOException("Failed: ${response.code}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Update an existing inventory item.
     */
    suspend fun updateItem(id: Int, item: InventoryItem): Result<InventoryItem> = withContext(Dispatchers.IO) {
        try {
            val data = item.toCreateJson().toMutableMap()
            data["id"] = id
            val json = gson.toJson(data)
            val requestBody = json.toRequestBody(JSON)

            val request = buildRequest("api/inventory/item/update")
                .post(requestBody)
                .build()

            val response = client.newCall(request).execute()
            val body = response.body?.string() ?: ""

            if (response.isSuccessful) {
                val apiResp = gson.fromJson(body, ApiResponse::class.java)
                if (apiResp.success && apiResp.item != null) {
                    Result.success(apiResp.item)
                } else {
                    Result.failure(IOException(apiResp.error ?: "Unknown error"))
                }
            } else {
                Result.failure(IOException("Update failed: ${response.code}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun buildRequest(path: String): Request.Builder {
        var cleanBase = baseUrl.trim().trimEnd('/')
        if (cleanBase.isNotEmpty() && !cleanBase.startsWith("http://") && !cleanBase.startsWith("https://")) {
            cleanBase = "http://$cleanBase"
        }
        if (cleanBase.isEmpty()) {
            throw IllegalArgumentException("Server URL is empty. Please set your Server URL in Settings.")
        }
        val url = "$cleanBase/$path"
        val builder = Request.Builder().url(url)
        if (sessionCookie.isNotEmpty()) {
            builder.addHeader("Cookie", sessionCookie)
        }
        if (sitename.isNotEmpty()) {
            builder.addHeader("X-Sitename", sitename)
        }
        if (apiToken.isNotEmpty()) {
            builder.addHeader("Authorization", "Bearer $apiToken")
        }
        return builder
    }

    /**
     * Same login as the web app. Returns the session cookie. Does not use an API token.
     */
    suspend fun login(username: String, password: String): Result<String> = withContext(Dispatchers.IO) {
        try {
            val form = FormBody.Builder()
                .add("username", username)
                .add("password", password)
                .add("form_source", "login_form")
                .add("return_to", "/")
                .build()
            val request = buildRequest("user/do_login").post(form).build()
            val noRedirect = client.newBuilder()
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
            val response = noRedirect.newCall(request).execute()
            val body = response.body?.string() ?: ""
            val cookie = response.headers("Set-Cookie")
                .map { it.substringBefore(';').trim() }
                .filter { it.contains('=') }
                .joinToString("; ")
            val location = response.header("Location") ?: ""
            if (response.code in 300..399 && !location.contains("/user/login") && cookie.isNotEmpty()) {
                Result.success(cookie)
            } else if (body.contains("Invalid username") || body.contains("Invalid password") || body.contains("do not currently have access")) {
                val msg = when {
                    body.contains("do not currently have access") -> "This login has no access to $sitename"
                    body.contains("Invalid password") -> "Invalid password"
                    else -> "Invalid username or password"
                }
                Result.failure(IOException(msg))
            } else {
                Result.failure(IOException("Login failed (${response.code})"))
            }
        } catch (e: Exception) {
            Log.e("ApiClient", "Login error", e)
            Result.failure(e)
        }
    }

    suspend fun loadAdjustForm(): Result<AdjustForm> = withContext(Dispatchers.IO) {
        try {
            val response = client.newCall(buildRequest("Inventory/stock/adjust").get().build()).execute()
            val body = response.body?.string() ?: ""
            if (body.contains("/user/login") && !body.contains("location_id")) {
                return@withContext Result.failure(IOException("Not logged in"))
            }
            Result.success(
                AdjustForm(
                    items = parseOptions(body, "item_id"),
                    locations = parseOptions(body, "location_id")
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun onHand(itemId: String, locationId: String): Result<Double> = withContext(Dispatchers.IO) {
        try {
            val response = client.newCall(
                buildRequest("api/inventory/stock?item_id=$itemId&sitename=$sitename").get().build()
            ).execute()
            val body = response.body?.string() ?: "[]"
            val type = object : TypeToken<List<Map<String, Any>>>() {}.type
            val rows: List<Map<String, Any>> = gson.fromJson(body, type) ?: emptyList()
            val row = rows.firstOrNull { it["location_id"].toString().substringBefore('.') == locationId }
            val qty = (row?.get("quantity_on_hand") as? Number)?.toDouble() ?: 0.0
            Result.success(qty)
        } catch (e: Exception) {
            Result.success(0.0)
        }
    }

    suspend fun postStockAdjust(
        itemId: String,
        locationId: String,
        quantity: Double,
        transactionType: String,
        notes: String
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val form = FormBody.Builder()
                .add("item_id", itemId)
                .add("location_id", locationId)
                .add("quantity", quantity.toString())
                .add("transaction_type", transactionType)
                .add("notes", notes)
                .add("redirect_to", "/")
                .build()
            val noRedirect = client.newBuilder().followRedirects(false).followSslRedirects(false).build()
            val response = noRedirect.newCall(
                buildRequest("Inventory/stock/adjust").post(form).build()
            ).execute()
            val body = response.body?.string() ?: ""
            if (response.code in 300..399) {
                Result.success(Unit)
            } else if (body.contains("Stock adjustment failed")) {
                Result.failure(IOException("Stock adjustment failed"))
            } else if (body.contains("/user/login")) {
                Result.failure(IOException("Login expired. Log in again."))
            } else {
                Result.failure(IOException("Stock update failed (${response.code})"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun parseOptions(html: String, selectId: String): List<NamedId> {
        val block = Regex("id=\"$selectId\"[\\s\\S]*?</select>").find(html)?.value ?: return emptyList()
        return Regex("<option value=\"(\\d+)\"[^>]*>([^<]+)</option>").findAll(block).map { m ->
            NamedId(m.groupValues[1], m.groupValues[2].trim())
        }.toList()
    }
}

data class NamedId(val id: String, val label: String)
data class AdjustForm(val items: List<NamedId>, val locations: List<NamedId>)