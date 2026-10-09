package com.comserv.inventory.model

data class ApiResponse(
    val success: Boolean = false,
    val error: String? = null,
    val path: String? = null,
    val item: com.comserv.inventory.model.InventoryItem? = null,
    val items: List<com.comserv.inventory.model.InventoryItem>? = null,
    // Updater fields
    val versionCode: Int? = null,
    val versionName: String? = null,
    val apkUrl: String? = null,
    val releaseNotes: String? = null
)
