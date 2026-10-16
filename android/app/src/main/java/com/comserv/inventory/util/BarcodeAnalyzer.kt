package com.comserv.inventory.util

import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

class BarcodeAnalyzer(
    private val onBarcodeDetected: (barcode: String, type: String) -> Unit
) : ImageAnalysis.Analyzer {

    private val scanner = BarcodeScanning.getClient()

    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image ?: return
        val inputImage = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

        scanner.process(inputImage)
            .addOnSuccessListener { barcodes ->
                for (barcode in barcodes) {
                    barcode.rawValue?.let { rawValue ->
                        val type = when (barcode.format) {
                            Barcode.FORMAT_UPC_A,
                            Barcode.FORMAT_UPC_E -> "upc"
                            Barcode.FORMAT_EAN_13,
                            Barcode.FORMAT_EAN_8 -> "ean"
                            Barcode.FORMAT_QR_CODE -> "qr"
                            Barcode.FORMAT_CODABAR,
                            Barcode.FORMAT_CODE_128,
                            Barcode.FORMAT_CODE_39,
                            Barcode.FORMAT_CODE_93,
                            Barcode.FORMAT_DATA_MATRIX,
                            Barcode.FORMAT_ITF,
                            Barcode.FORMAT_PDF417,
                            Barcode.FORMAT_AZTEC -> "internal"
                            else -> "other"
                        }
                        Log.d("BarcodeAnalyzer", "Detected: $rawValue ($type)")
                        onBarcodeDetected(rawValue, type)
                    }
                }
            }
            .addOnFailureListener { e ->
                Log.e("BarcodeAnalyzer", "Scan error", e)
            }
            .addOnCompleteListener {
                imageProxy.close()
            }
    }
}