package com.comserv.inventory

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.comserv.inventory.api.ApiClient
import com.comserv.inventory.api.NamedId
import com.comserv.inventory.util.PreferencesManager
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CountStockScreen(
    photoUri: Uri?,
    scannedBarcode: String,
    onTakePhoto: () -> Unit,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { PreferencesManager(context) }

    var mode by remember { mutableStateOf(PreferencesManager.MODE_LAN) }
    var port by remember { mutableStateOf(PreferencesManager.DEFAULT_PORT) }
    var cookie by remember { mutableStateOf("") }
    var sitename by remember { mutableStateOf(PreferencesManager.DEFAULT_SITENAME) }
    var locations by remember { mutableStateOf<List<NamedId>>(emptyList()) }
    var items by remember { mutableStateOf<List<NamedId>>(emptyList()) }
    var locationId by remember { mutableStateOf("") }
    var itemId by remember { mutableStateOf("") }
    var counted by remember { mutableStateOf("") }
    var colourName by remember { mutableStateOf("") }
    var colourHex by remember { mutableStateOf("") }
    var barcode by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { prefs.networkMode.collect { mode = it } }
    LaunchedEffect(Unit) { prefs.sitename.collect { sitename = it } }
    LaunchedEffect(Unit) { prefs.port.collect { port = it } }
    LaunchedEffect(Unit) { prefs.sessionCookie.collect { cookie = it } }

    val serverUrl = PreferencesManager.serverUrl(mode, sitename, port)

    LaunchedEffect(serverUrl, cookie) {
        if (serverUrl.isBlank() || cookie.isBlank()) return@LaunchedEffect
        val client = ApiClient(serverUrl, sessionCookie = cookie, sitename = sitename)
        client.loadAdjustForm().fold(
            onSuccess = { form ->
                items = form.items
                locations = form.locations
                if (locationId.isBlank() && form.locations.isNotEmpty()) {
                    locationId = form.locations.first().id
                }
            },
            onFailure = { status = it.message ?: "Could not load locations" }
        )
    }

    LaunchedEffect(photoUri) {
        val uri = photoUri ?: return@LaunchedEffect
        val file = uriToFile(context, uri) ?: return@LaunchedEffect
        val bmp = BitmapFactory.decodeFile(file.absolutePath) ?: return@LaunchedEffect
        val (name, hex) = dominantColour(bmp)
        colourName = name
        colourHex = hex
        bmp.recycle()
    }

    LaunchedEffect(scannedBarcode, items) {
        if (scannedBarcode.isNotEmpty()) {
            barcode = scannedBarcode
            val match = items.firstOrNull { it.label.contains(scannedBarcode, ignoreCase = true) }
            if (match != null) itemId = match.id
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row {
            TextButton(onClick = onBack) { Text("← Back") }
            Text("Count stock", style = MaterialTheme.typography.titleLarge)
        }
        Text(
            "Take a colour photo of the item in its place. The colour is read from the photo. You confirm the count; the app writes that number and location into accounting.",
            style = MaterialTheme.typography.bodySmall
        )
        Button(onClick = onTakePhoto, modifier = Modifier.fillMaxWidth()) {
            Text(if (photoUri == null) "Take colour photo" else "Retake photo")
        }
        if (colourName.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Canvas(modifier = Modifier.size(28.dp)) {
                    drawRect(colorFromHex(colourHex), size = Size(size.width, size.height))
                }
                Text("Colour from photo: $colourName  $colourHex")
            }
        }
        if (barcode.isNotEmpty()) {
            Text("Barcode in photo: $barcode")
        }

        val itemLabel = items.firstOrNull { it.id == itemId }?.label ?: "Select item"
        var itemOpen by remember { mutableStateOf(false) }
        ExposedDropdownMenuBox(expanded = itemOpen, onExpandedChange = { itemOpen = it }) {
            OutlinedTextField(
                value = itemLabel,
                onValueChange = {},
                readOnly = true,
                label = { Text("Item") },
                modifier = Modifier.menuAnchor().fillMaxWidth()
            )
            ExposedDropdownMenu(expanded = itemOpen, onDismissRequest = { itemOpen = false }) {
                items.forEach { row ->
                    DropdownMenuItem(
                        text = { Text(row.label) },
                        onClick = { itemId = row.id; itemOpen = false }
                    )
                }
            }
        }

        val locLabel = locations.firstOrNull { it.id == locationId }?.label ?: "Select location"
        var locOpen by remember { mutableStateOf(false) }
        ExposedDropdownMenuBox(expanded = locOpen, onExpandedChange = { locOpen = it }) {
            OutlinedTextField(
                value = locLabel,
                onValueChange = {},
                readOnly = true,
                label = { Text("Location") },
                modifier = Modifier.menuAnchor().fillMaxWidth()
            )
            ExposedDropdownMenu(expanded = locOpen, onDismissRequest = { locOpen = false }) {
                locations.forEach { row ->
                    DropdownMenuItem(
                        text = { Text(row.label) },
                        onClick = { locationId = row.id; locOpen = false }
                    )
                }
            }
        }

        OutlinedTextField(
            value = counted,
            onValueChange = { counted = it.filter { ch -> ch.isDigit() || ch == '.' } },
            label = { Text("Counted quantity") },
            modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal)
        )

        Button(
            onClick = {
                val qty = counted.toDoubleOrNull()
                if (itemId.isBlank() || locationId.isBlank() || qty == null) {
                    status = "Item, location, and counted quantity are required"
                    return@Button
                }
                busy = true
                status = ""
                scope.launch {
                    val client = ApiClient(serverUrl, sessionCookie = cookie, sitename = sitename)
                    val onHand = client.onHand(itemId, locationId).getOrDefault(0.0)
                    val delta = qty - onHand
                    if (delta == 0.0) {
                        busy = false
                        status = "Stock already matches the count ($qty)."
                        return@launch
                    }
                    val type = if (delta > 0) "adjust_up" else "adjust_down"
                    val notes = buildString {
                        append("Photo count")
                        if (colourName.isNotEmpty()) append(". Colour: $colourName $colourHex")
                        if (barcode.isNotEmpty()) append(". Barcode: $barcode")
                        append(". Counted $qty, was $onHand.")
                    }
                    val result = client.postStockAdjust(itemId, locationId, kotlin.math.abs(delta), type, notes)
                    busy = false
                    result.fold(
                        onSuccess = {
                            status = "Stock updated. Counted $qty at $locLabel."
                            Toast.makeText(context, "Stock updated", Toast.LENGTH_SHORT).show()
                        },
                        onFailure = { status = it.message ?: "Stock update failed" }
                    )
                }
            },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (busy) "Saving…" else "Update stock and location")
        }
        if (status.isNotEmpty()) Text(status)
    }
}

private fun dominantColour(bmp: Bitmap): Pair<String, String> {
    val w = bmp.width
    val h = bmp.height
    var r = 0L
    var g = 0L
    var b = 0L
    var n = 0L
    val step = 8
    var y = h / 5
    while (y < h * 4 / 5) {
        var x = w / 5
        while (x < w * 4 / 5) {
            val p = bmp.getPixel(x, y)
            val pr = (p shr 16) and 0xff
            val pg = (p shr 8) and 0xff
            val pb = p and 0xff
            val max = maxOf(pr, pg, pb)
            val min = minOf(pr, pg, pb)
            if (max > 40 && min < 245) {
                r += pr
                g += pg
                b += pb
                n++
            }
            x += step
        }
        y += step
    }
    if (n == 0L) return "unknown" to "#000000"
    val rr = (r / n).toInt()
    val gg = (g / n).toInt()
    val bb = (b / n).toInt()
    val hex = String.format("#%02X%02X%02X", rr, gg, bb)
    return nameColour(rr, gg, bb) to hex
}

private fun nameColour(r: Int, g: Int, b: Int): String {
    val max = maxOf(r, g, b)
    val min = minOf(r, g, b)
    if (max - min < 18) {
        return when {
            max < 60 -> "black"
            max > 200 -> "white"
            else -> "grey"
        }
    }
    return when {
        r > g && r > b && r - g > 30 && g > b + 20 -> "orange"
        r > g && r > b -> "red"
        g > r && g > b -> "green"
        b > r && b > g && r > 80 -> "purple"
        b > r && b > g -> "blue"
        r > 180 && g > 180 && b < 80 -> "yellow"
        r > 160 && g > 80 && b > 140 -> "pink"
        else -> "mixed"
    }
}

private fun colorFromHex(hex: String): Color {
    return try {
        Color(android.graphics.Color.parseColor(hex))
    } catch (_: Exception) {
        Color.Gray
    }
}
