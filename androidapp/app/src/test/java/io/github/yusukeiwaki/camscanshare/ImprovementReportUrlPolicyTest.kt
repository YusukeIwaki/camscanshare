package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.data.reporting.isAllowedCleartextReportHost
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImprovementReportUrlPolicyTest {
    @Test
    fun allowsPrivateIntranetIpv4RangesForCleartextReports() {
        assertTrue(isAllowedCleartextReportHost("10.0.0.1"))
        assertTrue(isAllowedCleartextReportHost("10.255.255.255"))
        assertTrue(isAllowedCleartextReportHost("192.168.0.1"))
        assertTrue(isAllowedCleartextReportHost("192.168.255.255"))
    }

    @Test
    fun rejectsNonIntranetIpv4AndHostnamesForCleartextReports() {
        assertFalse(isAllowedCleartextReportHost("172.16.0.1"))
        assertFalse(isAllowedCleartextReportHost("192.167.255.255"))
        assertFalse(isAllowedCleartextReportHost("example.com"))
        assertFalse(isAllowedCleartextReportHost("localhost"))
    }

    @Test
    fun rejectsMalformedIpv4ForCleartextReports() {
        assertFalse(isAllowedCleartextReportHost("10.0.0"))
        assertFalse(isAllowedCleartextReportHost("10.0.0.256"))
        assertFalse(isAllowedCleartextReportHost("10.0.0.1.2"))
        assertFalse(isAllowedCleartextReportHost("010.0.0.1"))
    }
}
