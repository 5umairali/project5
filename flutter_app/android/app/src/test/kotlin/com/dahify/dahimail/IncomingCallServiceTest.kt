package com.dahify.dahimail

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class IncomingCallServiceTest {
    @Test fun ringingServiceKeepsNotificationAndStopsOnCancellation() {
        val context = RuntimeEnvironment.getApplication()
        val data = mapOf("call_id" to "42", "sent_at" to "${System.currentTimeMillis() / 1000}", "ttl" to "45")
        NativePushReceiver.showCall(context, data)
        val controller = Robolectric.buildService(IncomingCallService::class.java,
            Intent(context, IncomingCallService::class.java).putExtra("call_data", JSONObject(data).toString())).create().startCommand(0, 1)
        assertNotNull(shadowOf(controller.get()).lastForegroundNotification)
        NativePushReceiver.minimizeCall(context, data)
        assertNull(context.getSystemService(NotificationManager::class.java).activeNotifications.single().notification.fullScreenIntent)
        NativePushReceiver.dismissCall(context, 42)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, context.getSystemService(NotificationManager::class.java).activeNotifications.size)
        controller.destroy()
    }
    @Test fun expiredServiceIntentNeverResurrectsCall() {
        val context = RuntimeEnvironment.getApplication()
        val data = mapOf("call_id" to "43", "sent_at" to "0")
        val controller = Robolectric.buildService(IncomingCallService::class.java,
            Intent(context, IncomingCallService::class.java).putExtra("call_data", JSONObject(data).toString())).create().startCommand(0, 1)
        assertNull(shadowOf(controller.get()).lastForegroundNotification)
        assertTrue(shadowOf(controller.get()).isStoppedBySelf)
        controller.destroy()
    }
}
