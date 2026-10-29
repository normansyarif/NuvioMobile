package com.nuvio.app.features.trakt

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class EpisodeLookupCacheTest {
    @Test
    fun `concurrent home and detail lookups share a request and cache the result`() = runTest {
        val cache = EpisodeLookupCache<String, List<Int>>()
        val response = CompletableDeferred<List<Int>>()
        var calls = 0
        val home = async { cache.get("parks") { calls++; response.await() } }
        runCurrent()
        val detail = async { cache.get("parks") { calls++; listOf(99) } }
        runCurrent()
        response.complete(listOf(24, 1))
        assertEquals(listOf(24, 1), home.await())
        assertEquals(home.await(), detail.await())
        assertEquals(listOf(24, 1), cache.get("parks") { error("already cached") })
        assertEquals(1, calls)
    }

    @Test
    fun `cancelling the owner releases the live home waiter and permits retry`() = runTest {
        val cache = EpisodeLookupCache<String, Int>()
        val owner = async { cache.get("parks") { awaitCancellation() } }
        runCurrent()
        val home = async { runCatching { cache.get("parks") { 99 } } }
        runCurrent()
        owner.cancelAndJoin()
        runCurrent()
        assertTrue(home.isCompleted, "Home must not await the cancelled owner forever")
        assertIs<EpisodeLookupInterruptedException>(home.await().exceptionOrNull())
        assertEquals(31, cache.get("parks") { 31 })
    }

    @Test
    fun `a metadata timeout releases waiters without cancelling their screen`() = runTest {
        val cache = EpisodeLookupCache<String, Int>()
        val timedLookup = async {
            withTimeoutOrNull(3_500) { cache.get("parks") { awaitCancellation() } }
        }
        runCurrent()
        val home = async { runCatching { cache.get("parks") { 99 } } }
        assertNull(timedLookup.await())
        assertIs<EpisodeLookupInterruptedException>(home.await().exceptionOrNull())
        assertEquals(31, cache.get("parks") { 31 })
    }

    @Test
    fun `a failed lookup releases every waiter and does not cache the failure`() = runTest {
        val cache = EpisodeLookupCache<String, Int>()
        val response = CompletableDeferred<Int>()
        val owner = async { runCatching { cache.get("parks") { response.await() } } }
        runCurrent()
        val waiter = async { runCatching { cache.get("parks") { 99 } } }
        runCurrent()
        response.completeExceptionally(IllegalStateException("temporary network error"))
        assertTrue(owner.await().isFailure)
        assertTrue(waiter.await().isFailure)
        assertEquals(31, cache.get("parks") { 31 })
    }

    @Test
    fun `cancelling a waiter leaves the shared owner running`() = runTest {
        val cache = EpisodeLookupCache<String, Int>()
        val response = CompletableDeferred<Int>()
        val owner = async { cache.get("parks") { response.await() } }
        runCurrent()
        val waiter = async { cache.get("parks") { 99 } }
        runCurrent()
        waiter.cancelAndJoin()
        response.complete(31)
        assertEquals(31, owner.await())
        assertEquals(31, cache.get("parks") { 99 })
    }

    @Test
    fun `clearing for another profile releases waiters and rejects the old result`() = runTest {
        val cache = EpisodeLookupCache<String, Int>()
        val response = CompletableDeferred<Int>()
        val owner = async { runCatching { cache.get("parks") { response.await() } } }
        runCurrent()
        val waiter = async { runCatching { cache.get("parks") { 99 } } }
        runCurrent()
        cache.clear()
        assertIs<EpisodeLookupInterruptedException>(waiter.await().exceptionOrNull())
        assertEquals(7, cache.get("parks") { 7 })
        response.complete(31)
        assertTrue(owner.await().isFailure)
        assertEquals(7, cache.get("parks") { 99 })
    }
}
