from __future__ import annotations

# pyright: reportMissingImports=false

from unittest.mock import MagicMock

import pytest

from mavlink_relay_server.registry import SessionRegistry


@pytest.mark.asyncio
async def test_register_vehicle_and_lookup(registry: SessionRegistry) -> None:
    proto = MagicMock(name="vehicle-proto")
    session = await registry.register_vehicle("BB_000001", proto, (0, 4, 8))

    assert session.vehicle_id == "BB_000001"
    assert session.protocol is proto
    assert session.control_stream_id == 0
    assert session.priority_stream_id == 4
    assert session.bulk_stream_id == 8

    assert registry.vehicle_count == 1
    assert registry.get_vehicle("BB_000001") is session


@pytest.mark.asyncio
async def test_register_gcs_and_lookup(registry: SessionRegistry) -> None:
    proto = MagicMock(name="gcs-proto")
    session = await registry.register_gcs("gcs-alpha", proto, (0, 4, 8))

    assert session.gcs_id == "gcs-alpha"
    assert session.protocol is proto
    assert session.control_stream_id == 0
    assert session.priority_stream_id == 4
    assert session.bulk_stream_id == 8
    assert session.subscribed_vehicle_id is None

    assert registry.gcs_count == 1
    assert registry.get_gcs("gcs-alpha") is session


@pytest.mark.asyncio
async def test_register_vehicle_duplicate_raises(registry: SessionRegistry) -> None:
    proto1 = MagicMock(name="vehicle-proto1")
    proto2 = MagicMock(name="vehicle-proto2")
    await registry.register_vehicle("BB_000001", proto1, (0, 4, 8))
    with pytest.raises(ValueError, match="already registered"):
        await registry.register_vehicle("BB_000001", proto2, (0, 4, 8))


@pytest.mark.asyncio
async def test_register_gcs_duplicate_replaces_session(
    registry: SessionRegistry,
) -> None:
    proto1 = MagicMock(name="gcs-proto1")
    proto2 = MagicMock(name="gcs-proto2")
    await registry.register_gcs("gcs-alpha", proto1, (0, 4, 8))
    session2 = await registry.register_gcs("gcs-alpha", proto2, (0, 4, 8))
    assert session2.protocol is proto2
    assert registry.get_gcs("gcs-alpha") is session2


@pytest.mark.asyncio
async def test_stale_unregister_gcs_does_not_evict_replacement(
    registry: SessionRegistry,
) -> None:
    proto1 = MagicMock(name="gcs-proto1")
    proto2 = MagicMock(name="gcs-proto2")
    await registry.register_gcs("gcs-alpha", proto1, (0, 4, 8))
    session2 = await registry.register_gcs("gcs-alpha", proto2, (0, 4, 8))
    await registry.unregister_gcs("gcs-alpha", protocol=proto1)
    assert registry.get_gcs("gcs-alpha") is session2


@pytest.mark.asyncio
async def test_subscribe_success_sets_subscription_and_backref(
    registry: SessionRegistry,
) -> None:
    vproto = MagicMock(name="vehicle-proto")
    gproto = MagicMock(name="gcs-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    await registry.register_gcs("gcs-alpha", gproto, (0, 4, 8))

    ok = await registry.subscribe("gcs-alpha", "BB_000001")
    assert ok is True
    assert registry.subscription_count == 1

    gcs_session = registry.get_gcs("gcs-alpha")
    assert gcs_session is not None
    assert gcs_session.subscribed_vehicle_id == "BB_000001"

    subs = registry.get_subscribers("BB_000001")
    assert [s.gcs_id for s in subs] == ["gcs-alpha"]

    veh = registry.get_vehicle_for_gcs("gcs-alpha")
    assert veh is not None
    assert veh.vehicle_id == "BB_000001"


@pytest.mark.asyncio
async def test_subscribe_unknown_vehicle_returns_false(
    registry: SessionRegistry,
) -> None:
    gproto = MagicMock(name="gcs-proto")
    await registry.register_gcs("gcs-alpha", gproto, (0, 4, 8))
    ok = await registry.subscribe("gcs-alpha", "BB_999999")
    assert ok is False
    assert registry.subscription_count == 0


@pytest.mark.asyncio
async def test_subscribe_unknown_gcs_returns_false(registry: SessionRegistry) -> None:
    vproto = MagicMock(name="vehicle-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    ok = await registry.subscribe("missing", "BB_000001")
    assert ok is False
    assert registry.subscription_count == 0


@pytest.mark.asyncio
async def test_subscribe_moves_from_previous_vehicle(registry: SessionRegistry) -> None:
    v1 = MagicMock(name="vehicle1")
    v2 = MagicMock(name="vehicle2")
    g = MagicMock(name="gcs")
    await registry.register_vehicle("BB_000001", v1, (0, 4, 8))
    await registry.register_vehicle("BB_000002", v2, (0, 4, 8))
    await registry.register_gcs("gcs-alpha", g, (0, 4, 8))

    assert await registry.subscribe("gcs-alpha", "BB_000001") is True
    assert await registry.subscribe("gcs-alpha", "BB_000002") is False

    assert registry.subscription_count == 1
    assert [s.gcs_id for s in registry.get_subscribers("BB_000001")] == ["gcs-alpha"]
    assert [s.gcs_id for s in registry.get_subscribers("BB_000002")] == []


@pytest.mark.asyncio
async def test_unregister_vehicle_returns_subscribers_and_clears_gcs_backref(
    registry: SessionRegistry,
) -> None:
    vproto = MagicMock(name="vehicle-proto")
    gproto = MagicMock(name="gcs-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    await registry.register_gcs("gcs-alpha", gproto, (0, 4, 8))
    await registry.subscribe("gcs-alpha", "BB_000001")

    removed = await registry.unregister_vehicle("BB_000001")
    assert removed == {"gcs-alpha"}
    assert registry.vehicle_count == 0
    assert registry.subscription_count == 0

    gcs = registry.get_gcs("gcs-alpha")
    assert gcs is not None
    assert gcs.subscribed_vehicle_id is None
    assert registry.get_vehicle_for_gcs("gcs-alpha") is None


@pytest.mark.asyncio
async def test_unregister_gcs_removes_from_subscription_sets(
    registry: SessionRegistry,
) -> None:
    vproto = MagicMock(name="vehicle-proto")
    gproto = MagicMock(name="gcs-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    await registry.register_gcs("gcs-alpha", gproto, (0, 4, 8))
    await registry.subscribe("gcs-alpha", "BB_000001")

    assert registry.subscription_count == 1
    await registry.unregister_gcs("gcs-alpha")
    assert registry.gcs_count == 0
    assert registry.subscription_count == 0
    assert registry.get_subscribers("BB_000001") == []


@pytest.mark.asyncio
async def test_get_subscribers_skips_stale_ids(registry: SessionRegistry) -> None:
    vproto = MagicMock(name="vehicle-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    registry._subscriptions["BB_000001"].add("ghost")  # type: ignore[attr-defined]
    assert registry.get_subscribers("BB_000001") == []


@pytest.mark.asyncio
async def test_subscribe_already_subscribed_gcs_returns_false(
    registry: SessionRegistry,
) -> None:
    vproto = MagicMock(name="vehicle-proto")
    gproto = MagicMock(name="gcs-proto")
    await registry.register_vehicle("BB_000001", vproto, (0, 4, 8))
    await registry.register_gcs("gcs-alpha", gproto, (0, 4, 8))

    ok1 = await registry.subscribe("gcs-alpha", "BB_000001")
    assert ok1 is True
    assert registry.subscription_count == 1

    ok2 = await registry.subscribe("gcs-alpha", "BB_000001")
    assert ok2 is False
    assert registry.subscription_count == 1
