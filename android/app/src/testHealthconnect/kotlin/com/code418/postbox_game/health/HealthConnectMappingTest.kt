package com.code418.postbox_game.health

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectMappingTest {
    @Test
    fun eligibleTypesAreOnFootOnly() {
        assertEquals("walking", HealthConnectMapping.exerciseTypeName(ExerciseSessionRecord.EXERCISE_TYPE_WALKING))
        assertEquals("running", HealthConnectMapping.exerciseTypeName(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING))
        assertEquals("hiking", HealthConnectMapping.exerciseTypeName(ExerciseSessionRecord.EXERCISE_TYPE_HIKING))
        assertNull(HealthConnectMapping.exerciseTypeName(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL))
        assertNull(HealthConnectMapping.exerciseTypeName(ExerciseSessionRecord.EXERCISE_TYPE_BIKING))
        assertEquals(listOf("walking", "running", "hiking"), HealthConnectMapping.ELIGIBLE_EXERCISE_TYPES.values.toList())
    }

    @Test
    fun recordingMethodsMapToWireNames() {
        assertEquals("active", HealthConnectMapping.recordingMethodName(Metadata.RECORDING_METHOD_ACTIVELY_RECORDED))
        assertEquals("automatic", HealthConnectMapping.recordingMethodName(Metadata.RECORDING_METHOD_AUTOMATICALLY_RECORDED))
        assertEquals("manual", HealthConnectMapping.recordingMethodName(Metadata.RECORDING_METHOD_MANUAL_ENTRY))
        assertEquals("unknown", HealthConnectMapping.recordingMethodName(Metadata.RECORDING_METHOD_UNKNOWN))
    }

    @Test
    fun statusNames() {
        assertEquals("unsupported_os", HealthConnectMapping.statusName(27, 3, 3, 2))
        assertEquals("available", HealthConnectMapping.statusName(34, 3, 3, 2))
        assertEquals("update_required", HealthConnectMapping.statusName(33, 2, 3, 2))
        assertEquals("not_installed", HealthConnectMapping.statusName(33, 1, 3, 2))
    }

    @Test
    fun encodeRouteSortsByTimeAndDropsBadFixes() {
        val r = HealthConnectMapping.encodeRoute(
            listOf(
                HealthConnectMapping.RouteFix(3000, 51.3, -0.3, null),
                HealthConnectMapping.RouteFix(1000, 51.1, -0.1, 4.0),
                HealthConnectMapping.RouteFix(2000, Double.NaN, -0.2, 5.0),
                HealthConnectMapping.RouteFix(1500, 95.0, -0.2, 5.0),
            ),
        )
        assertArrayEquals(longArrayOf(1000, 3000), r.t)
        assertArrayEquals(doubleArrayOf(51.1, 51.3), r.lat, 0.0)
        assertEquals(4.0, r.acc[0], 0.0)
        assertTrue(r.acc[1].isNaN())
        assertEquals("data", r.toMap()["status"])
    }

    @Test
    fun permissionsAreReadOnly() {
        assertTrue(HealthConnectMapping.PERMISSIONS.all { it.startsWith("android.permission.health.READ_") })
    }
}
