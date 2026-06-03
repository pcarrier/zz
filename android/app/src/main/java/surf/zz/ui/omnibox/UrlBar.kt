package surf.zz.ui.omnibox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.ManageSearch
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Compact editable URL/search field with a leading search icon, a find button, and a
 * clear button. Port of `URLBar.swift`.
 *
 * Deviations from iOS (documented):
 *  - The `Cmd-F` tooltip (`.help("Find on Page (⌘F)")`) is dropped on a touch target.
 *  - `selectAll()` is implemented inline with a [TextFieldValue] selection spanning the
 *    whole string when focus is gained, rather than dispatching a UIResponder/NSResponder
 *    `selectAll(_:)` action.
 */
@Composable
fun UrlBar(
    text: String,
    onTextChange: (String) -> Unit,
    focused: Boolean,
    onFocusChange: (Boolean) -> Unit,
    placeholder: String = "Search or enter URL",
    findEnabled: Boolean = true,
    onFind: () -> Unit = {},
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }

    // Mirror the external `text` String onto a TextFieldValue that also carries the
    // selection/cursor. We keep the value locally so the cursor position is preserved
    // across recompositions, syncing only the text content from the parent.
    var fieldValue by remember {
        mutableStateOf(TextFieldValue(text, TextRange(text.length)))
    }
    if (fieldValue.text != text) {
        // External edits (e.g. programmatic URL set) win; place cursor at end.
        fieldValue = fieldValue.copy(
            text = text,
            selection = TextRange(text.length),
        )
    }

    // select-all on focus gained (iOS: selectAll()).
    LaunchedEffect(focused) {
        if (focused) {
            focusRequester.requestFocus()
            fieldValue = fieldValue.copy(selection = TextRange(0, fieldValue.text.length))
        }
    }

    val borderColor = if (focused) {
        MaterialTheme.colorScheme.primary.copy(alpha = 0.48f)
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.18f)
    }
    val backgroundColor = MaterialTheme.colorScheme.onSurfaceVariant
        .copy(alpha = if (focused) 0.14f else 0.10f)
    val shape = RoundedCornerShape(7.dp)

    Row(
        modifier = modifier
            .clip(shape)
            .background(backgroundColor)
            .border(0.75.dp, borderColor, shape)
            .padding(horizontal = 9.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // editableArea: leading magnifyingglass + text field, fills available width.
        // Tapping anywhere in this area focuses the field (iOS: .onTapGesture).
        Row(
            modifier = Modifier
                .weight(1f)
                .clickableNoIndication {
                    if (!focused) {
                        focusRequester.requestFocus()
                        onFocusChange(true)
                    }
                },
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = Icons.Filled.Search,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            BasicTextField(
                value = fieldValue,
                onValueChange = { newValue ->
                    fieldValue = newValue
                    if (newValue.text != text) onTextChange(newValue.text)
                },
                modifier = Modifier
                    .weight(1f)
                    .focusRequester(focusRequester)
                    .onFocusChanged { state ->
                        if (state.isFocused != focused) onFocusChange(state.isFocused)
                    },
                singleLine = true,
                textStyle = LocalTextStyle.current.copy(
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 15.sp,
                ),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(
                    autoCorrectEnabled = false,
                    capitalization = KeyboardCapitalization.None,
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go,
                ),
                keyboardActions = KeyboardActions(onGo = { onSubmit() }),
                decorationBox = { innerTextField ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (fieldValue.text.isEmpty()) {
                            Text(
                                text = placeholder,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                    .copy(alpha = 0.6f),
                                fontSize = 15.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        innerTextField()
                    }
                },
            )
        }

        // Find button.
        Box(
            modifier = Modifier
                .size(24.dp)
                .alpha(if (findEnabled) 1f else 0.35f)
                .clickableNoIndication(enabled = findEnabled) { onFind() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Filled.ManageSearch,
                contentDescription = "Find on Page",
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        // Clear button: only when there is text AND the field is focused.
        if (text.isNotEmpty() && focused) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clickableNoIndication {
                        fieldValue = fieldValue.copy(text = "", selection = TextRange.Zero)
                        onTextChange("")
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Cancel,
                    contentDescription = "Clear",
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                )
            }
        }
    }
}

/** Tap handler without ripple/indication, mirroring SwiftUI `.buttonStyle(.plain)`. */
@Composable
private fun Modifier.clickableNoIndication(
    enabled: Boolean = true,
    onClick: () -> Unit,
): Modifier =
    this.clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        enabled = enabled,
        onClick = onClick,
    )
