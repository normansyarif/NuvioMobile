package com.nuvio.app.features.trakt

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Shares episode lookups without leaving waiters suspended after owner cancellation. */
internal class EpisodeLookupCache<K : Any, V> {
    private val lock = SynchronizedObject()
    private val cached = mutableMapOf<K, V>()
    private val pending = mutableMapOf<K, CompletableDeferred<V>>()
    private var generation = 0L

    suspend fun get(key: K, load: suspend () -> V): V {
        val lease = synchronized(lock) {
            if (cached.containsKey(key)) return cached.getValue(key)
            val existing = pending[key]
            if (existing != null) {
                Lease(existing, false, generation)
            } else {
                val created = CompletableDeferred<V>()
                pending[key] = created
                Lease(created, true, generation)
            }
        }
        if (!lease.owner) {
            return try {
                lease.result.await()
            } catch (error: CancellationException) {
                currentCoroutineContext().ensureActive()
                // A different screen owned the cancelled lookup. The current
                // screen is still alive and must be allowed to retry.
                throw EpisodeLookupInterruptedException()
            }
        }

        try {
            val value = load()
            synchronized(lock) {
                if (generation != lease.generation) {
                    throw CancellationException("Episode lookup cache was cleared")
                }
                cached[key] = value
                lease.result.complete(value)
            }
            return value
        } catch (error: Throwable) {
            // Complete even on cancellation. Cleanup must not suspend in a
            // cancelled coroutine, and waiters must never await an orphan.
            lease.result.completeExceptionally(error)
            throw error
        } finally {
            synchronized(lock) {
                if (pending[key] === lease.result) pending.remove(key)
            }
        }
    }

    fun clear() = synchronized(lock) {
        generation += 1
        cached.clear()
        pending.values.forEach { it.cancel(CancellationException("Episode lookup cache was cleared")) }
        pending.clear()
    }

    private data class Lease<V>(
        val result: CompletableDeferred<V>,
        val owner: Boolean,
        val generation: Long,
    )
}

internal class EpisodeLookupInterruptedException : Exception("Shared episode lookup was interrupted")
