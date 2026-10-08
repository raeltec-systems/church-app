package zm.bickafue.bic_kafue_mobile

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

/**
 * Story 3.6: creates the default notification channel at every process start
 * (also when a push starts the process with no activity), so background
 * reminders display on Android 8+. Messages carry only the generic title and
 * body.
 */
class BicKafueApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(
                    "reminders",
                    "Reminders",
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
    }
}
