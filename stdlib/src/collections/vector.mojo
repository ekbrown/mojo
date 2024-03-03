# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Defines InlinedFixedVector.

You can import these APIs from the `collections` package. For example:

```mojo
from collections.vector import InlinedFixedVector
```
"""

from memory.unsafe import Pointer, Reference

from utils.static_tuple import StaticTuple

# TODO: Remove once we're ready to rip the bandaid off of the old
# type of DynamicVector everywhere.  This (and the alias inside `list.mojo`)
# are kept around only for a short amount of time right now.
from . import List

# ===----------------------------------------------------------------------===#
# _VecIter
# ===----------------------------------------------------------------------===#


@value
struct _VecIter[
    type: AnyRegType,
    vec_type: AnyRegType,
    deref: fn (Pointer[vec_type], Int) -> type,
](Sized):
    """Iterator for any random-access container"""

    var i: Int
    var size: Int
    var vec: Pointer[vec_type]

    fn __next__(inout self) -> type:
        self.i += 1
        return deref(self.vec, self.i - 1)

    fn __len__(self) -> Int:
        return self.size - self.i


# ===----------------------------------------------------------------------===#
# InlinedFixedVector
# ===----------------------------------------------------------------------===#


@always_inline
fn _calculate_fixed_vector_default_size[type: AnyRegType]() -> Int:
    alias prefered_bytecount = 64
    alias sizeof_type = sizeof[type]()

    @parameter
    if sizeof_type >= 256:
        return 0

    alias prefered_inline_bytes = prefered_bytecount - sizeof[
        InlinedFixedVector[type, 0]
    ]()
    alias num_elements = prefered_inline_bytes // sizeof_type
    return num_elements or 1


struct InlinedFixedVector[
    type: AnyRegType, size: Int = _calculate_fixed_vector_default_size[type]()
](Sized):
    """A dynamically-allocated vector with small-vector optimization and a fixed
    maximum capacity.

    The `InlinedFixedVector` does not resize or implement bounds checks. It is
    initialized with both a small-vector size (specified at compile time) and a
    maximum capacity (specified at runtime).

    The first `size` elements are stored in the statically-allocated small
    vector storage. Any remaining elements are stored in dynamically-allocated
    storage.

    When it is deallocated, it frees its memory.

    TODO: It should call its element destructors once we have traits.

    This data structure is useful for applications where the number of required
    elements is not known at compile time, but once known at runtime, is
    guaranteed to be equal to or less than a certain capacity.

    Parameters:
        type: The type of the elements.
        size: The statically-known small-vector size.
    """

    alias static_size: Int = size
    alias static_data_type = StaticTuple[type, size]
    var static_data: Self.static_data_type
    """The underlying static storage, used for small vectors."""
    var dynamic_data: Pointer[type]
    """The underlying dynamic storage, used to grow large vectors."""
    var current_size: Int
    """The number of elements in the vector."""
    var capacity: Int
    """The maximum number of elements that can fit in the vector."""

    @always_inline
    fn __init__(inout self, capacity: Int):
        """Constructs `InlinedFixedVector` with the given capacity.

        The dynamically allocated portion is `capacity - size`.

        Args:
            capacity: The requested maximum capacity of the vector.
        """
        self.static_data = Self.static_data_type()  # Undef initialization
        self.dynamic_data = Pointer[type]()
        if capacity > Self.static_size:
            self.dynamic_data = Pointer[type].alloc(capacity - size)
        self.current_size = 0
        self.capacity = capacity

    # TODO: Probably don't want this to be implicitly no-op copyable when we
    # have ownership.
    @always_inline
    fn __copyinit__(inout self, existing: Self):
        """Creates a shallow copy (doesn't copy the underlying elements).

        Args:
            existing: The `InlinedFixedVector` to copy.
        """
        self.static_data = existing.static_data
        self.dynamic_data = existing.dynamic_data
        self.current_size = existing.current_size
        self.capacity = existing.capacity

    @always_inline
    fn _del_old(self):
        """Destroys the object."""
        if self.capacity > Self.static_size:
            self.dynamic_data.free()

    @always_inline
    fn deepcopy(self) -> Self:
        """Creates a deep copy of this vector.

        Returns:
            The created copy of this vector.
        """
        var res = Self(self.capacity)
        for i in range(len(self)):
            res.append(self[i])
        return res

    @always_inline
    fn append(inout self, value: type):
        """Appends a value to this vector.

        Args:
            value: The value to append.
        """
        debug_assert(
            self.current_size < self.capacity,
            "index must be less than capacity",
        )
        if self.current_size < Self.static_size:
            self.static_data[self.current_size] = value
        else:
            self.dynamic_data[self.current_size - Self.static_size] = value
        self.current_size += 1

    @always_inline
    fn __len__(self) -> Int:
        """Gets the number of elements in the vector.

        Returns:
            The number of elements in the vector.
        """
        return self.current_size

    @always_inline
    fn __getitem__(self, i: Int) -> type:
        """Gets a vector element at the given index.

        Args:
            i: The index of the element.

        Returns:
            The element at the given index.
        """
        debug_assert(
            -self.current_size <= i < self.current_size,
            "index must be within bounds",
        )
        var normalized_idx = i
        if i < 0:
            normalized_idx += len(self)

        if normalized_idx < Self.static_size:
            return self.static_data[normalized_idx]

        return self.dynamic_data[normalized_idx - Self.static_size]

    @always_inline
    fn __setitem__(inout self, i: Int, value: type):
        """Sets a vector element at the given index.

        Args:
            i: The index of the element.
            value: The value to assign.
        """
        debug_assert(
            -self.current_size <= i < self.current_size,
            "index must be within bounds",
        )

        var normalized_idx = i
        if i < 0:
            normalized_idx += len(self)

        if normalized_idx < Self.static_size:
            self.static_data[normalized_idx] = value
        else:
            self.dynamic_data[normalized_idx - Self.static_size] = value

    fn clear(inout self):
        """Clears the elements in the vector."""
        self.current_size = 0

    @staticmethod
    fn _deref_iter_impl(selfptr: Pointer[Self], i: Int) -> type:
        return selfptr[][i]

    alias _iterator = _VecIter[type, Self, Self._deref_iter_impl]

    fn __iter__(inout self) -> Self._iterator:
        """Iterate over the vector.

        Returns:
            An iterator to the start of the vector.
        """
        return Self._iterator(
            0, self.current_size, __get_lvalue_as_address(self)
        )
