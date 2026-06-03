package surf.zz.layout

import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import surf.zz.persistence.UuidSerializer

/**
 * Binary space-partitioning tree. Leaves carry a [Tab] id; splits divide their
 * area along an [Axis] at a [Split.ratio].
 *
 * Direct 1:1 port of the Swift `BSPNode` enum (`ios/zz/BrowserStore.swift`). The
 * Swift `enum` with an `indirect case` becomes a Kotlin sealed interface with two
 * `data class` cases. Every method ports verbatim as a pure function over an
 * immutable tree: each transform returns a new tree and never mutates `this`.
 *
 * Serializes through the shared `ZzJson` (`classDiscriminator = "type"`) as
 * `{"type":"leaf",...}` / `{"type":"split",...}`. This is a fresh JSON shape on
 * Android (not byte-identical to Swift's Codable enum encoding); acceptable
 * because Android starts with no saved state.
 */
@Serializable
sealed interface BspNode {

    /** Stable identity of this node: the tab id for a leaf, the split id for a split. */
    val id: UUID

    @Serializable
    @SerialName("leaf")
    data class Leaf(
        @Serializable(with = UuidSerializer::class) val tabId: UUID,
    ) : BspNode {
        override val id: UUID get() = tabId
    }

    @Serializable
    @SerialName("split")
    data class Split(
        @Serializable(with = UuidSerializer::class) override val id: UUID,
        val axis: Axis,
        val ratio: Double,
        val first: BspNode,
        val second: BspNode,
    ) : BspNode

    @Serializable
    enum class Axis {
        @SerialName("horizontal") HORIZONTAL,
        @SerialName("vertical") VERTICAL,
    }

    // MARK: - Traversal / queries

    /** Pre-order list of all tab ids carried by leaves under this node. */
    fun tabIDs(): List<UUID> = when (this) {
        is Leaf -> listOf(tabId)
        is Split -> first.tabIDs() + second.tabIDs()
    }

    /**
     * Returns a copy of the tree in which any leaf whose tab id has already
     * appeared earlier in a pre-order traversal is rewritten with a fresh UUID,
     * guaranteeing every leaf carries a unique id.
     */
    fun deduplicatingLeafIDs(seen: MutableSet<UUID>): BspNode = when (this) {
        is Leaf ->
            if (seen.add(tabId)) this
            else Leaf(tabId = UUID.randomUUID())
        is Split -> {
            // Dedup split ids in the same pre-order walk: a snapshot with a repeated
            // split UUID makes split-id-keyed ops (ratio/axis/equalize/selectGroup/
            // divider drag) short-circuit on the first match and target the wrong node.
            val newID = if (seen.add(id)) id else UUID.randomUUID()
            Split(
                id = newID,
                axis = axis,
                ratio = ratio,
                first = first.deduplicatingLeafIDs(seen),
                second = second.deduplicatingLeafIDs(seen),
            )
        }
    }

    fun contains(tabID: UUID): Boolean = when (this) {
        is Leaf -> tabId == tabID
        is Split -> first.contains(tabID) || second.contains(tabID)
    }

    fun containsSplit(splitID: UUID): Boolean = when (this) {
        is Leaf -> false
        is Split -> id == splitID || first.containsSplit(splitID) || second.containsSplit(splitID)
    }

    fun tabIDs(inSplit: UUID): List<UUID>? = when (this) {
        is Leaf -> null
        is Split -> {
            if (id == inSplit) tabIDs()
            else first.tabIDs(inSplit) ?: second.tabIDs(inSplit)
        }
    }

    fun parentSplitID(containingTab: UUID): UUID? = when (this) {
        is Leaf -> null
        is Split -> when {
            first.contains(containingTab) -> first.parentSplitID(containingTab) ?: id
            second.contains(containingTab) -> second.parentSplitID(containingTab) ?: id
            else -> null
        }
    }

    fun parentSplitID(containingSplit: UUID): UUID? = when (this) {
        is Leaf -> null
        is Split -> {
            if (first.id == containingSplit || second.id == containingSplit) id
            else first.parentSplitID(containingSplit = containingSplit)
                ?: second.parentSplitID(containingSplit = containingSplit)
        }
    }

    // MARK: - Pure tree rewrites

    fun replacingLeaf(tabID: UUID, with: UUID): BspNode = when (this) {
        is Leaf -> if (tabId == tabID) Leaf(tabId = with) else this
        is Split -> Split(
            id = id,
            axis = axis,
            ratio = ratio,
            first = first.replacingLeaf(tabID, with),
            second = second.replacingLeaf(tabID, with),
        )
    }

    fun splitting(
        tabID: UUID,
        axis: Axis,
        newTabID: UUID,
        side: SplitSide = SplitSide.AFTER,
    ): BspNode = when (this) {
        is Leaf -> {
            if (tabId != tabID) {
                this
            } else {
                val existing: BspNode = Leaf(tabId = tabId)
                val fresh: BspNode = Leaf(tabId = newTabID)
                Split(
                    id = UUID.randomUUID(),
                    axis = axis,
                    ratio = 0.5,
                    first = if (side == SplitSide.BEFORE) fresh else existing,
                    second = if (side == SplitSide.BEFORE) existing else fresh,
                )
            }
        }
        is Split -> Split(
            id = id,
            axis = this.axis,
            ratio = ratio,
            first = first.splitting(tabID, axis, newTabID, side),
            second = second.splitting(tabID, axis, newTabID, side),
        )
    }

    fun splittingGroup(
        splitID: UUID,
        axis: Axis,
        newTabID: UUID,
        side: SplitSide = SplitSide.AFTER,
    ): BspNode = when (this) {
        is Leaf -> this
        is Split -> {
            if (id == splitID) {
                val existing: BspNode = this
                val fresh: BspNode = Leaf(tabId = newTabID)
                Split(
                    id = UUID.randomUUID(),
                    axis = axis,
                    ratio = 0.5,
                    first = if (side == SplitSide.BEFORE) fresh else existing,
                    second = if (side == SplitSide.BEFORE) existing else fresh,
                )
            } else {
                Split(
                    id = id,
                    axis = this.axis,
                    ratio = ratio,
                    first = first.splittingGroup(splitID, axis, newTabID, side),
                    second = second.splittingGroup(splitID, axis, newTabID, side),
                )
            }
        }
    }

    /** Returns the tree with [tabID]'s leaf removed, collapsing the parent split, or null if the whole tree was that leaf. */
    fun removing(tabID: UUID): BspNode? = when (this) {
        is Leaf -> if (tabId == tabID) null else this
        is Split -> when {
            first.contains(tabID) -> {
                val newA = first.removing(tabID) ?: return second
                Split(id = id, axis = axis, ratio = ratio, first = newA, second = second)
            }
            second.contains(tabID) -> {
                val newB = second.removing(tabID) ?: return first
                Split(id = id, axis = axis, ratio = ratio, first = first, second = newB)
            }
            else -> this
        }
    }

    /** Tab ids of the sibling subtree that expands to fill the space when [tabID]'s leaf is removed. */
    fun tabIDsExpandedByRemoving(tabID: UUID): List<UUID> = when (this) {
        is Leaf -> emptyList()
        is Split -> when {
            first.contains(tabID) -> {
                if (first is Leaf) second.tabIDs()
                else first.tabIDsExpandedByRemoving(tabID)
            }
            second.contains(tabID) -> {
                if (second is Leaf) first.tabIDs()
                else second.tabIDsExpandedByRemoving(tabID)
            }
            else -> emptyList()
        }
    }

    /** Tab id that should receive focus after [tabID] is removed (the adjacent edge leaf), or null. */
    fun tabIDToFocusAfterRemoving(tabID: UUID): UUID? = when (this) {
        is Leaf -> null
        is Split -> when {
            first.contains(tabID) -> {
                if (first is Leaf) {
                    val direction = if (axis == Axis.HORIZONTAL) Direction.DOWN else Direction.RIGHT
                    second.edgeLeaf(opposite = direction)
                } else {
                    first.tabIDToFocusAfterRemoving(tabID)
                }
            }
            second.contains(tabID) -> {
                if (second is Leaf) {
                    val direction = if (axis == Axis.HORIZONTAL) Direction.UP else Direction.LEFT
                    first.edgeLeaf(opposite = direction)
                } else {
                    second.tabIDToFocusAfterRemoving(tabID)
                }
            }
            else -> null
        }
    }

    fun settingRatio(ratio: Double, forSplit: UUID): BspNode = when (this) {
        is Leaf -> this
        is Split -> {
            if (id == forSplit) {
                Split(
                    id = id,
                    axis = axis,
                    ratio = ratio.coerceIn(0.05, 0.95),
                    first = first,
                    second = second,
                )
            } else {
                Split(
                    id = id,
                    axis = axis,
                    ratio = this.ratio,
                    first = first.settingRatio(ratio, forSplit),
                    second = second.settingRatio(ratio, forSplit),
                )
            }
        }
    }

    fun equalizingRatios(inSplit: UUID): BspNode = when (this) {
        is Leaf -> this
        is Split -> {
            if (id == inSplit) {
                equalizingAllRatios()
            } else {
                Split(
                    id = id,
                    axis = axis,
                    ratio = ratio,
                    first = first.equalizingRatios(inSplit),
                    second = second.equalizingRatios(inSplit),
                )
            }
        }
    }

    private fun equalizingAllRatios(): BspNode = when (this) {
        is Leaf -> this
        is Split -> Split(
            id = id,
            axis = axis,
            ratio = 0.5,
            first = first.equalizingAllRatios(),
            second = second.equalizingAllRatios(),
        )
    }

    fun togglingAxis(forSplit: UUID): BspNode = when (this) {
        is Leaf -> this
        is Split -> {
            val nextAxis = if (axis == Axis.HORIZONTAL) Axis.VERTICAL else Axis.HORIZONTAL
            Split(
                id = id,
                axis = if (id == forSplit) nextAxis else axis,
                ratio = ratio,
                first = first.togglingAxis(forSplit),
                second = second.togglingAxis(forSplit),
            )
        }
    }

    fun ratio(forSplit: UUID): Double? = when (this) {
        is Leaf -> null
        is Split -> {
            if (id == forSplit) ratio
            else first.ratio(forSplit) ?: second.ratio(forSplit)
        }
    }

    /** Tab id of the spatial neighbor of [tabID] in [direction], or null if there is none. */
    fun neighbor(of: UUID, direction: Direction): UUID? {
        val path = mutableListOf<PathStep>()
        if (!pathTo(of, path)) return null
        for (step in path) {
            val node = step.node
            if (node is Split) {
                val aligned =
                    (node.axis == Axis.HORIZONTAL && (direction == Direction.UP || direction == Direction.DOWN)) ||
                        (node.axis == Axis.VERTICAL && (direction == Direction.LEFT || direction == Direction.RIGHT))
                if (!aligned) continue
                val goSecond = (direction == Direction.DOWN || direction == Direction.RIGHT)
                if (step.fromFirst == goSecond) {
                    val target = if (step.fromFirst) node.second else node.first
                    return target.edgeLeaf(opposite = direction)
                }
            }
        }
        return null
    }

    private class PathStep(val node: BspNode, val fromFirst: Boolean)

    /**
     * Records, deepest-first, the chain of splits from the leaf carrying [tabID]
     * up to the root, tagging at each level whether the child containing the leaf
     * was the split's `first` branch. Returns whether the leaf was found.
     */
    private fun pathTo(tabID: UUID, path: MutableList<PathStep>): Boolean = when (this) {
        is Leaf -> tabId == tabID
        is Split -> when {
            first.pathTo(tabID, path) -> {
                path.add(PathStep(this, fromFirst = true))
                true
            }
            second.pathTo(tabID, path) -> {
                path.add(PathStep(this, fromFirst = false))
                true
            }
            else -> false
        }
    }

    /**
     * Tab id of the leaf on the edge facing the side a neighbor is approaching
     * from. For a split aligned with [direction] it descends toward the entering
     * edge; for an unaligned split it descends the `first` branch.
     */
    private fun edgeLeaf(opposite: Direction): UUID = when (this) {
        is Leaf -> tabId
        is Split -> {
            val aligned =
                (axis == Axis.HORIZONTAL && (opposite == Direction.UP || opposite == Direction.DOWN)) ||
                    (axis == Axis.VERTICAL && (opposite == Direction.LEFT || opposite == Direction.RIGHT))
            if (aligned) {
                val pickFirst = (opposite == Direction.DOWN || opposite == Direction.RIGHT)
                (if (pickFirst) first else second).edgeLeaf(opposite = opposite)
            } else {
                first.edgeLeaf(opposite = opposite)
            }
        }
    }
}

/** Spatial navigation direction. Ports the Swift `enum Direction`. */
enum class Direction { UP, DOWN, LEFT, RIGHT }

/** Which side of an existing pane a new split places the fresh leaf on. Ports the Swift `enum SplitSide`. */
enum class SplitSide { BEFORE, AFTER }
