package com.comserv.inventory.model

import com.google.gson.annotations.SerializedName

data class InventoryItem(
    val id: Int? = null,
    val sku: String = "",
    val name: String = "",
    val description: String = "",
    val category: String = "",
    @SerializedName("item_origin")
    val itemOrigin: String = "purchased",
    @SerializedName("unit_of_measure")
    val unitOfMeasure: String = "each",
    @SerializedName("unit_cost")
    val unitCost: Double? = null,
    @SerializedName("unit_price")
    val unitPrice: Double? = null,
    val barcode: String = "",
    @SerializedName("barcode_type")
    val barcodeType: String = "",
    @SerializedName("image_path")
    val imagePath: String = "",
    @SerializedName("reorder_point")
    val reorderPoint: Int = 0,
    @SerializedName("reorder_quantity")
    val reorderQuantity: Int = 0,
    val status: String = "active",
    val notes: String = "",
    @SerializedName("is_consumable")
    val isConsumable: Boolean = false,
    @SerializedName("is_assemblable")
    val isAssemblable: Boolean = false,
) {
    fun toCreateJson(): Map<String, Any?> = mapOf(
        "sku" to sku,
        "name" to name,
        "description" to description.ifEmpty { null },
        "category" to category.ifEmpty { null },
        "item_origin" to itemOrigin,
        "unit_of_measure" to unitOfMeasure,
        "unit_cost" to unitCost,
        "unit_price" to unitPrice,
        "barcode" to barcode.ifEmpty { null },
        "barcode_type" to barcodeType.ifEmpty { null },
        "image_path" to imagePath.ifEmpty { null },
        "reorder_point" to reorderPoint,
        "reorder_quantity" to reorderQuantity,
        "status" to status,
        "notes" to notes.ifEmpty { null },
        "is_consumable" to (if (isConsumable) 1 else 0),
        "is_assemblable" to (if (isAssemblable) 1 else 0),
    )
}

data class ApiResponse(
    val success: Boolean = false,
    val item: InventoryItem? = null,
    val items: List<InventoryItem>? = null,
    val error: String? = null,
    val path: String? = null,  // for photo upload response
)

data class ApiError(
    val success: Boolean = false,
    val error: String = "",
    val code: String = "",
)