package app.ptt.talk

internal fun callServerErrorMessage(code: String): String? =
    when (code) {
        "ACCOUNT_ALREADY_IN_CALL" ->
            "This account is already in a call on another linked device. End that call first, or use a second test account to call between your devices."
        "CALL_ANSWERED_ELSEWHERE" ->
            "This call was answered on your other linked device."
        "CALL_ACTIVE_DEVICE_REQUIRED" ->
            "Continue this call from the linked device that answered it."
        else -> null
    }
