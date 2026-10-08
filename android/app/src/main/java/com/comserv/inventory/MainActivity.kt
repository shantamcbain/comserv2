@file:OptIn(ExperimentalPermissionsApi::class)
package com.comserv.inventory

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.comserv.inventory.api.ApiClient
import com.comserv.inventory.model.InventoryItem
import com.comserv.inventory.util.BarcodeAnalyzer
import com.comserv.inventory.util.PreferencesManager
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                ComservInventoryApp()
            }
        }
    }
}

@Composable
fun ComservInventoryApp() {
    var currentScreen by remember { mutableStateOf("main") }
    var scannedBarcode by remember { mutableStateOf("") }
    var scannedBarcodeType by remember { mutableStateOf("") }
    var capturedPhotoUri by remember { mutableStateOf<Uri?>(null) }

    when (currentScreen) {
        "main" -> MainScreen(
            onAddItem = { currentScreen = "add" },
            onSettings = { currentScreen = "settings" },
            onScanBarcode = { currentScreen = "scan" }
        )
        "add" -> AddItemScreen(
            initialBarcode = scannedBarcode,
            initialBarcodeType = scannedBarcodeType,
            photoUri = capturedPhotoUri,
            onBack = {
                scannedBarcode = ""
                scannedBarcodeType = ""
                capturedPhotoUri = null
                currentScreen = "main"
            },
            onOpenCamera = {
                currentScreen = "camera"
            }
        )
        "camera" -> CameraCaptureScreen(
            onPhotoCaptured = { uri ->
                capturedPhotoUri = uri
                currentScreen = "add"
            },
            onBarcodeScanned = { barcode, type ->
                scannedBarcode = barcode
                scannedBarcodeType = type
                currentScreen = "add"
            },
            onBack = { currentScreen = "add" }
        )
        "scan" -> BarcodeScreen(
            onBarcodeScanned = { barcode, type ->
                scannedBarcode = barcode
                scannedBarcodeType = type
                currentScreen = "add"
            },
            onBack = { currentScreen = "main" }
        )
        "settings" -> SettingsScreen(
            onBack = { currentScreen = "main" }
        )
    }
}

// ── Main Screen ──

@Composable
fun MainScreen(
    onAddItem: () -> Unit,
    onSettings: () -> Unit,
    onScanBarcode: () -> Unit
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text("Comserv Inventory", style = MaterialTheme.typography.headlineLarge)
        Spacer(Modifier.height(8.dp))
        Text("Inventory Accounting via API", style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(32.dp))

        Button(onClick = onScanBarcode, modifier = Modifier.fillMaxWidth().height(56.dp)) {
            Text("📷 Scan Barcode & Add Item")
        }
        Spacer(Modifier.height(12.dp))
        Button(onClick = onAddItem, modifier = Modifier.fillMaxWidth().height(56.dp)) {
            Text("➕ Add Item Manually")
        }
        Spacer(Modifier.height(12.dp))
        OutlinedButton(onClick = onSettings, modifier = Modifier.fillMaxWidth()) {
            Text("⚙️ Settings")
        }
    }
}

// ── Add Item Screen ──

@Composable
fun AddItemScreen(
    initialBarcode: String = "",
    initialBarcodeType: String = "",
    photoUri: Uri? = null,
    onBack: () -> Unit,
    onOpenCamera: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sku by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("") }
    var barcode by remember { mutableStateOf(initialBarcode) }
    var barcodeType by remember { mutableStateOf(initialBarcodeType) }
    var unitCost by remember { mutableStateOf("") }
    var unitPrice by remember { mutableStateOf("") }
    var reorderPoint by remember { mutableStateOf("") }
    var isConsumable by remember { mutableStateOf(false) }
    var isAssemblable by remember { mutableStateOf(false) }
    var imagePath by remember { mutableStateOf("") }
    var isSubmitting by remember { mutableStateOf(false) }
    var resultMsg by remember { mutableStateOf("") }
    val prefs = remember { PreferencesManager(context) }
    var serverUrl by remember { mutableStateOf("http://workstation.local:4001") }
    var apiToken by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        prefs.serverUrl.collect { serverUrl = it }
    }
    LaunchedEffect(Unit) {
        prefs.apiToken.collect { apiToken = it }
    }

    fun doSubmit() {
        if (sku.isBlank() || name.isBlank()) {
            resultMsg = "SKU and Name are required"
            return
        }
        isSubmitting = true
        resultMsg = ""
        val item = InventoryItem(
            sku = sku.trim(),
            name = name.trim(),
            description = description.trim(),
            category = category.trim(),
            barcode = barcode.trim(),
            barcodeType = barcodeType,
            unitCost = unitCost.toDoubleOrNull(),
            unitPrice = unitPrice.toDoubleOrNull(),
            reorderPoint = reorderPoint.toIntOrNull() ?: 0,
            isConsumable = isConsumable,
            isAssemblable = isAssemblable,
            imagePath = imagePath,
        )
        val client = ApiClient(serverUrl, apiToken)
        scope.launch {
            try {
                // If we have a photo, upload it first
                var finalImagePath = imagePath
                if (photoUri != null && finalImagePath.isBlank()) {
                    val file = uriToFile(context, photoUri)
                    if (file != null) {
                        val uploadResult = client.uploadPhoto(file)
                        uploadResult.onSuccess { path ->
                            finalImagePath = path
                        }.onFailure { e ->
                            Log.w("AddItem", "Photo upload failed: ${e.message}, using local path")
                        }
                    }
                }
                val updatedItem = item.copy(imagePath = finalImagePath)
                val result = client.createItem(updatedItem)
                result.onSuccess {
                    resultMsg = "✅ Created: ${it.id} — ${it.name}"
                    // Clear form for next scan
                    sku = ""
                    name = ""
                    barcode = ""
                    barcodeType = ""
                }.onFailure { e ->
                    resultMsg = "❌ Error: ${e.message}"
                }
            } catch (e: Exception) {
                resultMsg = "❌ Error: ${e.message}"
            }
            isSubmitting = false
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState())
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("← Back") }
            Text("Add Item", style = MaterialTheme.typography.titleLarge)
        }

        // Camera / scan section
        Button(onClick = onOpenCamera, modifier = Modifier.fillMaxWidth()) {
            Text("📷 Open Camera (photo + barcode)")
        }
        if (barcode.isNotEmpty()) {
            Text("📊 Scanned: $barcode ($barcodeType)", style = MaterialTheme.typography.bodySmall)
        }
        if (photoUri != null) {
            Text("📸 Photo captured (will upload on submit)", style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(12.dp))

        OutlinedTextField(value = sku, onValueChange = { sku = it }, label = { Text("SKU *") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name *") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text("Description") }, modifier = Modifier.fillMaxWidth(), maxLines = 2)
        OutlinedTextField(value = category, onValueChange = { category = it }, label = { Text("Category") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = barcode, onValueChange = { barcode = it }, label = { Text("Barcode") }, modifier = Modifier.fillMaxWidth())

        var barcodeTypeExpanded by remember { mutableStateOf(false) }
        Box(modifier = Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = barcodeType.ifEmpty { "— unknown —" },
                onValueChange = {},
                readOnly = true,
                label = { Text("Barcode Type") },
                modifier = Modifier.fillMaxWidth(),
                trailingIcon = { Text("▼") }
            )
            // Invisible click overlay
            TextButton(onClick = { barcodeTypeExpanded = true }, modifier = Modifier.fillMaxWidth().matchParentSize()) {}
        }
        DropdownMenu(expanded = barcodeTypeExpanded, onDismissRequest = { barcodeTypeExpanded = false }) {
            listOf("" to "— unknown —", "upc" to "UPC", "ean" to "EAN", "qr" to "QR", "internal" to "Internal / custom", "other" to "Other").forEach { (value, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = {
                    barcodeType = value
                    barcodeTypeExpanded = false
                })
            }
        }

        OutlinedTextField(value = unitCost, onValueChange = { unitCost = it }, label = { Text("Unit Cost") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        OutlinedTextField(value = unitPrice, onValueChange = { unitPrice = it }, label = { Text("Selling Price") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        OutlinedTextField(value = reorderPoint, onValueChange = { reorderPoint = it }, label = { Text("Reorder Point") }, modifier = Modifier.fillMaxWidth(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
        Row { Checkbox(checked = isConsumable, onCheckedChange = { isConsumable = it }); Text("Consumable", modifier = Modifier.align(Alignment.CenterVertically)) }
        Row { Checkbox(checked = isAssemblable, onCheckedChange = { isAssemblable = it }); Text("Has BOM / Recipe", modifier = Modifier.align(Alignment.CenterVertically)) }

        OutlinedTextField(
            value = imagePath,
            onValueChange = { imagePath = it },
            label = { Text("Image / Photo Path") },
            placeholder = { Text("NFS path or URL") },
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(8.dp))
        if (resultMsg.isNotEmpty()) {
            Text(resultMsg, color = if (resultMsg.startsWith("✅")) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        }

        Button(
            onClick = { doSubmit() },
            modifier = Modifier.fillMaxWidth().height(48.dp),
            enabled = !isSubmitting
        ) {
            Text(if (isSubmitting) "Creating..." else "✅ Create Item")
        }
        Spacer(Modifier.height(16.dp))
    }
}

// ── Camera Capture + Barcode Screen ──

@Composable
fun CameraCaptureScreen(
    onPhotoCaptured: (Uri) -> Unit,
    onBarcodeScanned: (barcode: String, type: String) -> Unit,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    var cameraProvider by remember { mutableStateOf<ProcessCameraProvider?>(null) }
    var scanCount by remember { mutableIntStateOf(0) }

    val cameraPermission = rememberPermissionState(Manifest.permission.CAMERA)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) {
            Toast.makeText(context, "Camera permission required", Toast.LENGTH_SHORT).show()
        }
    }

    LaunchedEffect(Unit) {
        if (!cameraPermission.status.isGranted) {
            launcher.launch(Manifest.permission.CAMERA)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            cameraProvider?.unbindAll()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(8.dp)) {
            TextButton(onClick = {
                cameraProvider?.unbindAll()
                onBack()
            }) { Text("← Back") }
            Text("Camera", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.weight(1f))
            Text("Scans: $scanCount", style = MaterialTheme.typography.bodySmall)
        }

        if (cameraPermission.status.isGranted) {
            Box(modifier = Modifier.weight(1f)) {
                AndroidView(
                    factory = { ctx ->
                        val previewView = PreviewView(ctx)
                        val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                        cameraProviderFuture.addListener({
                            try {
                                val provider = cameraProviderFuture.get()
                                cameraProvider = provider
                                val preview = Preview.Builder().build().also {
                                    it.setSurfaceProvider(previewView.surfaceProvider)
                                }
                                val capture = ImageCapture.Builder()
                                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                                    .build()
                                imageCapture = capture

                                val barcodeAnalysis = ImageAnalysis.Builder()
                                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                    .build()
                                    .also { analyzer ->
                                        analyzer.setAnalyzer(Executors.newSingleThreadExecutor(),
                                            BarcodeAnalyzer { barcode, type ->
                                                scanCount++
                                                onBarcodeScanned(barcode, type)
                                            }
                                        )
                                    }

                                provider.unbindAll()
                                provider.bindToLifecycle(
                                    lifecycleOwner,
                                    CameraSelector.DEFAULT_BACK_CAMERA,
                                    preview,
                                    capture,
                                    barcodeAnalysis
                                )
                            } catch (e: Exception) {
                                Log.e("Camera", "Error initializing camera", e)
                            }
                        }, ContextCompat.getMainExecutor(ctx))
                        previewView
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        } else {
            Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Camera permission needed for photo & barcode scanning")
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) {
                        Text("Grant Permission")
                    }
                }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            horizontalArrangement = Arrangement.SpaceEvenly
        ) {
            Button(
                onClick = {
                    val capture = imageCapture
                    if (capture == null) {
                        Toast.makeText(context, "Camera not ready yet", Toast.LENGTH_SHORT).show()
                        return@Button
                    }
                    val file = File(
                        context.getExternalFilesDir(Environment.DIRECTORY_PICTURES),
                        "ITEM_${System.currentTimeMillis()}.jpg"
                    )
                    val outputOptions = ImageCapture.OutputFileOptions.Builder(file).build()
                    capture.takePicture(
                        outputOptions,
                        ContextCompat.getMainExecutor(context),
                        object : ImageCapture.OnImageSavedCallback {
                            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                                val uri = Uri.fromFile(file)
                                onPhotoCaptured(uri)
                            }
                            override fun onError(exc: ImageCaptureException) {
                                Toast.makeText(context, "Photo error: ${exc.message}", Toast.LENGTH_SHORT).show()
                            }
                        }
                    )
                },
                enabled = imageCapture != null
            ) {
                Text("📸 Capture Photo")
            }
        }
    }
}

// ── Scan-only Barcode Screen ──

@Composable
fun BarcodeScreen(
    onBarcodeScanned: (barcode: String, type: String) -> Unit,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var cameraProvider by remember { mutableStateOf<ProcessCameraProvider?>(null) }
    var scanCount by remember { mutableIntStateOf(0) }

    val cameraPermission = rememberPermissionState(Manifest.permission.CAMERA)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (!granted) Toast.makeText(context, "Camera permission needed", Toast.LENGTH_SHORT).show()
    }

    LaunchedEffect(Unit) {
        if (!cameraPermission.status.isGranted) {
            launcher.launch(Manifest.permission.CAMERA)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            cameraProvider?.unbindAll()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(8.dp)) {
            TextButton(onClick = {
                cameraProvider?.unbindAll()
                onBack()
            }) { Text("← Back") }
            Text("Barcode Scanner", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.weight(1f))
            Text("Scans: $scanCount", style = MaterialTheme.typography.bodySmall)
        }

        if (cameraPermission.status.isGranted) {
            Box(modifier = Modifier.weight(1f)) {
                AndroidView(
                    factory = { ctx ->
                        val previewView = PreviewView(ctx)
                        val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                        cameraProviderFuture.addListener({
                            try {
                                val provider = cameraProviderFuture.get()
                                cameraProvider = provider
                                val preview = Preview.Builder().build().also {
                                    it.setSurfaceProvider(previewView.surfaceProvider)
                                }
                                val analysis = ImageAnalysis.Builder()
                                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                    .build()
                                    .also { a ->
                                        a.setAnalyzer(Executors.newSingleThreadExecutor(),
                                            BarcodeAnalyzer { barcode, type ->
                                                scanCount++
                                                onBarcodeScanned(barcode, type)
                                            }
                                        )
                                    }
                                provider.unbindAll()
                                provider.bindToLifecycle(
                                    lifecycleOwner,
                                    CameraSelector.DEFAULT_BACK_CAMERA,
                                    preview,
                                    analysis
                                )
                            } catch (e: Exception) {
                                Log.e("Barcode", "Bind error", e)
                            }
                        }, ContextCompat.getMainExecutor(ctx))
                        previewView
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        } else {
            Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Camera permission needed for barcode scanning")
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) {
                        Text("Grant Permission")
                    }
                }
            }
        }
    }
}

// ── Settings Screen ──

@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { PreferencesManager(context) }
    var serverUrl by remember { mutableStateOf("") }
    var apiToken by remember { mutableStateOf("") }
    var saved by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        prefs.serverUrl.collect { serverUrl = it }
    }
    LaunchedEffect(Unit) {
        prefs.apiToken.collect { apiToken = it }
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("← Back") }
            Text("Settings", style = MaterialTheme.typography.titleLarge)
        }
        Spacer(Modifier.height(16.dp))

        OutlinedTextField(
            value = serverUrl,
            onValueChange = { serverUrl = it },
            label = { Text("Server URL") },
            placeholder = { Text("http://workstation.local:4001") },
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = apiToken,
            onValueChange = { apiToken = it },
            label = { Text("API Token") },
            placeholder = { Text("Bearer token from /api/generate-token") },
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                scope.launch {
                    prefs.setServerUrl(serverUrl)
                    prefs.setApiToken(apiToken)
                    saved = true
                }
            }) { Text("💾 Save") }
            if (saved) {
                Text("✓ Saved", color = MaterialTheme.colorScheme.primary, modifier = Modifier.align(Alignment.CenterVertically))
            }
        }

        Spacer(Modifier.height(24.dp))
        Text("Connection Info", style = MaterialTheme.typography.titleSmall)
        Text("The app connects to your Comserv server over ZeroTier (plain HTTP). Make sure the server URL is reachable from this device. Generate an API token on the server at /api/generate-token (requires web login first).", style = MaterialTheme.typography.bodySmall)
    }
}

// ── Utility Functions ──

fun uriToFile(context: android.content.Context, uri: Uri): File? {
    return try {
        val inputStream = context.contentResolver.openInputStream(uri) ?: return null
        val file = File(context.cacheDir, "photo_${System.currentTimeMillis()}.jpg")
        FileOutputStream(file).use { output ->
            inputStream.copyTo(output)
        }
        inputStream.close()
        // Compress for upload
        val bmp = BitmapFactory.decodeFile(file.absolutePath)
        if (bmp != null) {
            val scaled = Bitmap.createScaledBitmap(bmp, 1024, (1024f * bmp.height / bmp.width).toInt(), true)
            FileOutputStream(file).use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            }
            if (scaled != bmp) scaled.recycle()
            bmp.recycle()
        }
        file
    } catch (e: Exception) {
        Log.e("uriToFile", "Error converting URI", e)
        null
    }
}

fun startCamera(
    context: android.content.Context,
    lifecycleOwner: androidx.lifecycle.LifecycleOwner,
    onReady: (ProcessCameraProvider, ImageCapture) -> Unit
) {
    val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
    cameraProviderFuture.addListener({
        val provider = cameraProviderFuture.get()
        val imageCapture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
        onReady(provider, imageCapture)
    }, ContextCompat.getMainExecutor(context))
}