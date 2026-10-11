package app.ptt.talk

import android.app.Activity
import android.app.AlertDialog
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Native searchable directory with a separate select → name/review → create group flow. */
internal class NewMessageDialog(
    private val activity: Activity,
    private val members: List<DirectoryMember>,
    private val create: (List<DirectoryMember>, String, (String?) -> Unit) -> Unit,
) {
    private val selected = linkedSetOf<String>()
    private var group = false
    private var review = false
    private var busy = false
    private var groupName = ""
    private val content = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        val padding = (20 * resources.displayMetrics.density).toInt()
        setPadding(padding, 0, padding, padding)
    }
    private val dialog = AlertDialog.Builder(activity).setView(content)
        .setNegativeButton("Cancel", null).create()

    fun show() { render(); dialog.show() }

    private fun render() {
        content.removeAllViews()
        dialog.setTitle(if (review) "Review group" else if (group) "New group" else "New message")
        fun label(text: String) = TextView(activity).apply { this.text = text; textSize = 16f; setPadding(0, 12, 0, 12) }
        fun button(text: String, action: () -> Unit) = Button(activity).apply {
            this.text = text; isAllCaps = false; setOnClickListener { if (!busy) action() }
        }
        val error = label("").apply { visibility = View.GONE; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        val status = label("").apply { visibility = View.GONE; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        fun submit(chosen: List<DirectoryMember>) {
            if (busy) return
            busy = true
            dialog.setCancelable(false)
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.isEnabled = false
            status.text = "Opening encrypted conversation…"
            status.visibility = View.VISIBLE
            error.visibility = View.GONE
            create(chosen, if (group) groupName.trim() else "") { failure ->
                busy = false
                dialog.setCancelable(true)
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.isEnabled = true
                if (failure == null) dialog.dismiss() else {
                    status.visibility = View.GONE
                    error.text = "$failure\nYour selection is saved. Check your connection and try again."
                    error.visibility = View.VISIBLE
                }
            }
        }
        if (review) {
            content.addView(button("Back to members") { review = false; render() })
            val name = EditText(activity).apply { hint = "Group name"; setText(groupName); maxLines = 2 }
            content.addView(name)
            val chosen = members.filter { it.aci in selected }
            content.addView(label("Members · ${chosen.size + 1} of 8\nYou\n" + chosen.joinToString("\n") { it.displayName }))
            val confirm = button("Create group") { submit(chosen) }.apply { isEnabled = groupName.isNotBlank() }
            name.addTextChangedListener(watcher { groupName = it; confirm.isEnabled = it.isNotBlank() && !busy })
            content.addView(confirm)
        } else {
            content.addView(button(if (group) "Back to new message" else "New group") {
                group = !group; selected.clear(); render()
            })
            if (group) content.addView(label("Choose 2–7 teammates. Groups support eight people including you."))
            val search = EditText(activity).apply { hint = "Search teammates"; setSingleLine(true) }
            content.addView(search)
            val rows = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
            content.addView(ScrollView(activity).apply { addView(rows) }, LinearLayout.LayoutParams(-1, (280 * activity.resources.displayMetrics.density).toInt()))
            val next = button("Next") { review = true; render() }.apply { isEnabled = selected.size >= 2 }
            fun filter(query: String) {
                rows.removeAllViews()
                val visible = members.filter { it.displayName.contains(query, ignoreCase = true) }.sortedBy { it.displayName.lowercase() }
                if (visible.isEmpty()) rows.addView(label(if (query.isEmpty()) "No teammates yet. Ask your administrator to invite someone." else "No teammates match your search."))
                visible.forEach { member ->
                    if (group) rows.addView(CheckBox(activity).apply {
                        text = member.displayName; isChecked = member.aci in selected
                        setOnCheckedChangeListener { _, checked ->
                            if (busy || (checked && selected.size == 7)) { isChecked = member.aci in selected; return@setOnCheckedChangeListener }
                            if (checked) selected.add(member.aci) else selected.remove(member.aci)
                            next.isEnabled = selected.size >= 2
                        }
                    }) else rows.addView(button(member.displayName) { submit(listOf(member)) })
                }
            }
            search.addTextChangedListener(watcher { filter(it) })
            filter("")
            if (group) content.addView(next)
        }
        content.addView(status)
        content.addView(error)
    }

    private fun watcher(changed: (String) -> Unit) = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
        override fun afterTextChanged(s: Editable?) { changed(s?.toString().orEmpty()) }
    }
}
