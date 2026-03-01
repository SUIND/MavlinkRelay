"""Vehicle and GCS session registry for the MAVLink QUIC relay server."""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from mavlink_relay_server.protocol import RelayProtocol

logger = logging.getLogger(__name__)


@dataclass
class VehicleSession:
    """Represents an active vehicle (UAV) connection."""

    vehicle_id: str
    protocol: RelayProtocol
    control_stream_id: int
    priority_stream_id: int
    bulk_stream_id: int
    connected_at: float = field(default_factory=time.monotonic)
    write_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


@dataclass
class GCSSession:
    """Represents an active Ground Control Station connection."""

    gcs_id: str
    protocol: RelayProtocol
    control_stream_id: int
    priority_stream_id: int
    bulk_stream_id: int
    connected_at: float = field(default_factory=time.monotonic)
    subscribed_vehicle_id: str | None = None


class SessionRegistry:
    """Thread-safe (asyncio) registry for vehicle and GCS sessions and subscriptions."""

    def __init__(self) -> None:
        self._vehicles: dict[str, VehicleSession] = {}
        self._gcs: dict[str, GCSSession] = {}
        self._subscriptions: dict[str, set[str]] = {}  # vehicle_id -> set of gcs_ids
        self._lock: asyncio.Lock = asyncio.Lock()

    # ------------------------------------------------------------------
    # Properties (synchronous, no lock needed)
    # ------------------------------------------------------------------

    @property
    def vehicle_count(self) -> int:
        """Return the number of registered vehicles."""
        return len(self._vehicles)

    @property
    def gcs_count(self) -> int:
        """Return the number of registered GCS clients."""
        return len(self._gcs)

    @property
    def subscription_count(self) -> int:
        """Return the total number of (vehicle, gcs) subscription pairs."""
        return sum(len(subs) for subs in self._subscriptions.values())

    # ------------------------------------------------------------------
    # Mutations (async, protected by self._lock)
    # ------------------------------------------------------------------

    async def register_vehicle(
        self,
        vehicle_id: str,
        protocol: RelayProtocol,
        stream_ids: tuple[int, int, int],  # (control, priority, bulk)
    ) -> VehicleSession:
        """Register a vehicle connection.

        Args:
            vehicle_id: Unique identifier for the vehicle.
            protocol: The transport protocol instance for this vehicle.
            stream_ids: Tuple of (control_stream_id, priority_stream_id, bulk_stream_id).

        Returns:
            The newly created VehicleSession.

        Raises:
            ValueError: If vehicle_id is already registered.
        """
        async with self._lock:
            if vehicle_id in self._vehicles:
                raise ValueError(f"Vehicle {vehicle_id} already registered")
            control, priority, bulk = stream_ids
            session = VehicleSession(
                vehicle_id=vehicle_id,
                protocol=protocol,
                control_stream_id=control,
                priority_stream_id=priority,
                bulk_stream_id=bulk,
            )
            self._vehicles[vehicle_id] = session
            self._subscriptions[vehicle_id] = set()
            logger.info("Vehicle %s registered", vehicle_id)
            return session

    async def register_gcs(
        self,
        gcs_id: str,
        protocol: RelayProtocol,
        stream_ids: tuple[int, int, int],  # (control, priority, bulk)
    ) -> GCSSession:
        """Register a GCS connection.

        Args:
            gcs_id: Unique identifier for the GCS client.
            protocol: The transport protocol instance for this GCS.
            stream_ids: Tuple of (control_stream_id, priority_stream_id, bulk_stream_id).

        Returns:
            The newly created GCSSession.

        Raises:
            ValueError: If gcs_id is already registered.
        """
        async with self._lock:
            if gcs_id in self._gcs:
                raise ValueError(f"GCS '{gcs_id}' already registered")
            control, priority, bulk = stream_ids
            session = GCSSession(
                gcs_id=gcs_id,
                protocol=protocol,
                control_stream_id=control,
                priority_stream_id=priority,
                bulk_stream_id=bulk,
            )
            self._gcs[gcs_id] = session
            logger.info("GCS '%s' registered", gcs_id)
            return session

    async def unregister_vehicle(self, vehicle_id: str) -> set[str]:
        """Remove vehicle and all its subscriptions.

        Args:
            vehicle_id: The vehicle to remove.

        Returns:
            Set of gcs_ids that were subscribed to this vehicle.
        """
        async with self._lock:
            self._vehicles.pop(vehicle_id, None)
            subscribed_gcs_ids = self._subscriptions.pop(vehicle_id, set())
            # Clear subscribed_vehicle_id on each affected GCS session
            for gcs_id in subscribed_gcs_ids:
                gcs_session = self._gcs.get(gcs_id)
                if gcs_session is not None:
                    gcs_session.subscribed_vehicle_id = None
            logger.info(
                "Vehicle %s unregistered; notified %d GCS clients",
                vehicle_id,
                len(subscribed_gcs_ids),
            )
            return subscribed_gcs_ids

    async def unregister_gcs(self, gcs_id: str) -> None:
        """Remove GCS from registry and all subscription sets.

        Args:
            gcs_id: The GCS client to remove.
        """
        async with self._lock:
            session = self._gcs.pop(gcs_id, None)
            if session is not None and session.subscribed_vehicle_id is not None:
                vehicle_subs = self._subscriptions.get(session.subscribed_vehicle_id)
                if vehicle_subs is not None:
                    vehicle_subs.discard(gcs_id)
                session.subscribed_vehicle_id = None
            logger.info("GCS '%s' unregistered", gcs_id)

    async def subscribe(self, gcs_id: str, vehicle_id: str) -> bool:
        """Subscribe GCS to vehicle telemetry.

        Hard-rejects if the GCS is already subscribed to any vehicle.
        The GCS must disconnect and reconnect to subscribe to a different vehicle.

        Args:
            gcs_id: The GCS client to subscribe.
            vehicle_id: The vehicle to subscribe to.

        Returns:
            True if subscription succeeded, False otherwise.
        """
        async with self._lock:
            if vehicle_id not in self._vehicles:
                logger.warning(
                    "GCS '%s' tried to subscribe to unknown vehicle %s",
                    gcs_id,
                    vehicle_id,
                )
                return False

            gcs_session = self._gcs.get(gcs_id)
            if gcs_session is None:
                logger.warning(
                    "Unknown GCS '%s' tried to subscribe to vehicle %s",
                    gcs_id,
                    vehicle_id,
                )
                return False

            if gcs_session.subscribed_vehicle_id is not None:
                logger.warning(
                    "GCS '%s' tried to subscribe to vehicle %s but is already subscribed to %s — rejected",
                    gcs_id,
                    vehicle_id,
                    gcs_session.subscribed_vehicle_id,
                )
                return False

            self._subscriptions.setdefault(vehicle_id, set()).add(gcs_id)
            gcs_session.subscribed_vehicle_id = vehicle_id
            logger.info("GCS '%s' subscribed to vehicle %s", gcs_id, vehicle_id)
            return True

    # ------------------------------------------------------------------
    # Reads (synchronous — asyncio is single-threaded, no lock needed)
    # ------------------------------------------------------------------

    def get_vehicle(self, vehicle_id: str) -> VehicleSession | None:
        """Return the VehicleSession for the given vehicle_id, or None."""
        return self._vehicles.get(vehicle_id)

    def get_gcs(self, gcs_id: str) -> GCSSession | None:
        """Return the GCSSession for the given gcs_id, or None."""
        return self._gcs.get(gcs_id)

    def get_subscribers(self, vehicle_id: str) -> list[GCSSession]:
        """Return list of GCSSession objects subscribed to the given vehicle.

        Defensively skips any gcs_id no longer present in the GCS dict.

        Args:
            vehicle_id: The vehicle whose subscribers to look up.

        Returns:
            List of active GCSSession objects subscribed to this vehicle.
        """
        gcs_ids = self._subscriptions.get(vehicle_id, set())
        result = []
        for gcs_id in gcs_ids:
            session = self._gcs.get(gcs_id)
            if session is not None:
                result.append(session)
        return result

    def get_vehicle_for_gcs(self, gcs_id: str) -> VehicleSession | None:
        """Return the VehicleSession that the given GCS is subscribed to, or None.

        Args:
            gcs_id: The GCS client to look up.

        Returns:
            VehicleSession if the GCS is subscribed to one, otherwise None.
        """
        gcs_session = self._gcs.get(gcs_id)
        if gcs_session is None or gcs_session.subscribed_vehicle_id is None:
            return None
        return self._vehicles.get(gcs_session.subscribed_vehicle_id)
