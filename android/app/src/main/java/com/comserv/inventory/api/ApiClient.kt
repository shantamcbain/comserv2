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
    private val apiToken: String = ""
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
        if (apiToken.isNotEmpty()) {
            builder.addHeader("Authorization", "Bearer $apiToken")
        }
        return builder
    }
}