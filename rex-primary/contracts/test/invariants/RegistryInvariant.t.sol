// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {REXRegistry} from "../../src/REXRegistry.sol";
import {IREXRegistry} from "@rex-shared/IREXRegistry.sol";
import {MockREXPrimaryInfo} from "../mocks/MockREXPrimaryInfo.sol";

/// @notice Structural invariants of the directory under random register/unregister/setStatus/
/// setIssuer sequences. These are the properties BE6's catalog fold and the FE's direct-Registry
/// fallback both rely on: the key list is a set, every key has at least one live version, and the
/// two indexes (`_funds` and `_versions`) never disagree about which fund an address belongs to.
contract RegistryInvariantTest is Test {
    RegistryHandler internal handler;

    function setUp() public {
        handler = new RegistryHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RegistryHandler.doRegister.selector;
        selectors[1] = RegistryHandler.doRegisterBefore.selector;
        selectors[2] = RegistryHandler.doUnregister.selector;
        selectors[3] = RegistryHandler.doSetStatus.selector;
        selectors[4] = RegistryHandler.doSetIssuer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// `_keys` is a SET -- a duplicate would make the FE fallback list a fund twice.
    function invariant_keysAreUnique() public view {
        bytes32[] memory keys = handler.registry().allKeys();
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                assertTrue(keys[i] != keys[j], "duplicate key");
            }
        }
    }

    function invariant_fundCountMatchesAllKeys() public view {
        assertEq(handler.registry().fundCount(), handler.registry().allKeys().length);
    }

    /// No empty key may survive: a listed fund with zero versions is a dead directory row.
    function invariant_everyKeyHasAtLeastOneVersion() public view {
        bytes32[] memory keys = handler.registry().allKeys();
        for (uint256 i; i < keys.length; ++i) {
            assertGt(handler.registry().versionsOf(keys[i]).length, 0, "empty key");
        }
    }

    /// The two indexes agree: every address in a key's chain is registered UNDER that key, and its
    /// status is never the not-registered sentinel.
    function invariant_indexesAgree() public view {
        IREXRegistry registry = IREXRegistry(address(handler.registry()));
        bytes32[] memory keys = registry.allKeys();
        for (uint256 i; i < keys.length; ++i) {
            address[] memory chain = registry.versionsOf(keys[i]);
            for (uint256 j; j < chain.length; ++j) {
                (bytes32 key,, IREXRegistry.FundStatus status) = registry.fund(chain[j]);
                assertEq(key, keys[i], "version indexed under the wrong key");
                assertTrue(status != IREXRegistry.FundStatus.None, "live version with None status");
                assertTrue(registry.isRegistered(chain[j]), "chain member not registered");
            }
        }
    }

    /// The real ordering property, checked against an INDEPENDENT model the handler maintains:
    /// every chain must equal the sequence of register/registerBefore/unregister operations
    /// applied in order, element for element, and `latestOf` must be that model's last element.
    /// (The previous `latestOf == chain[len-1]` assertion was a tautology -- that IS how `latestOf`
    /// is implemented, so it could not fail; it never tested the shift/insert bookkeeping.)
    function invariant_chainsMatchModel() public view {
        IREXRegistry registry = IREXRegistry(address(handler.registry()));
        for (uint256 t; t < handler.tokenCount(); ++t) {
            address token = handler.tokenAt(t);
            bytes32 key = bytes32(uint256(uint160(token)));
            address[] memory actual = registry.versionsOf(key);
            address[] memory model = handler.expectedChain(token);

            assertEq(actual.length, model.length, "chain length diverged from the model");
            for (uint256 i; i < model.length; ++i) {
                assertEq(actual[i], model[i], "chain ORDER diverged from the model");
            }
            assertEq(
                registry.latestOf(key),
                model.length == 0 ? address(0) : model[model.length - 1],
                "latestOf is not the model's newest entry"
            );
            assertEq(registry.latestOfToken(token), registry.latestOf(key), "latestOfToken diverged");
        }
    }

    /// The direction `everyKeyHasAtLeastOneVersion` does NOT cover, and the dangerous one for a
    /// DISCOVERY contract: a fund with a live chain whose key is missing from `allKeys()` would be
    /// invisible to every client that enumerates (BE6's keeper, the FE fallback). `_keys` and
    /// `_versions` are kept in sync by hand, so this direction needs pinning too.
    function invariant_nonEmptyChainIsListed() public view {
        IREXRegistry registry = IREXRegistry(address(handler.registry()));
        bytes32[] memory listed = registry.allKeys();
        for (uint256 t; t < handler.tokenCount(); ++t) {
            bytes32 key = bytes32(uint256(uint160(handler.tokenAt(t))));
            if (registry.versionsOf(key).length == 0) continue;

            bool found;
            for (uint256 i; i < listed.length; ++i) {
                if (listed[i] == key) found = true;
            }
            assertTrue(found, "non-empty chain missing from allKeys");
        }
    }
}

/// @dev Drives the registry with a small fixed pool of tokens and pre-deployed REXPrimary mocks so
/// the fuzzer explores chains, not addresses.
contract RegistryHandler is Test {
    REXRegistry public registry;

    address[] internal primaries;
    address[3] internal tokens = [address(0xA1), address(0xA2), address(0xA3)];

    /// @dev The independent model `invariant_chainsMatchModel` compares against: what the chain
    /// SHOULD be after the operations performed, maintained here with plain array surgery rather
    /// than by asking the contract.
    mapping(address => address[]) internal expected;

    constructor() {
        registry = new REXRegistry();
        for (uint256 i; i < 6; ++i) {
            MockREXPrimaryInfo p = new MockREXPrimaryInfo(address(0x0FF0), 7336, address(0x0FACE), "1.0.1");
            p.setRemoteRouter(7336, bytes32(uint256(uint160(address(0xE7EC)))));
            primaries.push(address(p));
        }
    }

    function tokenCount() external pure returns (uint256) {
        return 3;
    }

    function tokenAt(uint256 i) external view returns (address) {
        return tokens[i];
    }

    function expectedChain(address token) external view returns (address[] memory) {
        return expected[token];
    }

    function _primary(uint256 seed) internal view returns (address) {
        return primaries[seed % primaries.length];
    }

    /// @dev `register`/`registerBefore` now reject a zero issuer, so the fuzzer's zero must be
    /// nudged off rather than reverting every call it generates.
    function _issuer(address raw) internal pure returns (address) {
        return raw == address(0) ? address(1) : raw;
    }

    function doRegister(uint256 pSeed, uint256 tSeed, address issuer) external {
        address p = _primary(pSeed);
        if (registry.isRegistered(p)) return;
        address token = tokens[tSeed % tokens.length];

        registry.register(p, token, _issuer(issuer));
        expected[token].push(p);
    }

    function doRegisterBefore(uint256 pSeed, uint256 tSeed, uint256 sSeed, address issuer) external {
        address p = _primary(pSeed);
        if (registry.isRegistered(p)) return;
        address token = tokens[tSeed % tokens.length];
        address[] storage chain = expected[token];
        if (chain.length == 0) return; // nothing to insert in front of

        uint256 at = sSeed % chain.length;
        address successor = chain[at];

        registry.registerBefore(p, token, _issuer(issuer), successor);

        chain.push(chain[chain.length - 1]);
        for (uint256 j = chain.length - 2; j > at; --j) {
            chain[j] = chain[j - 1];
        }
        chain[at] = p;
    }

    function doUnregister(uint256 pSeed) external {
        address p = _primary(pSeed);
        if (!registry.isRegistered(p)) return;
        (bytes32 key,,) = registry.fund(p);

        registry.unregister(p);

        address token = address(uint160(uint256(key)));
        address[] storage chain = expected[token];
        for (uint256 i; i < chain.length; ++i) {
            if (chain[i] == p) {
                for (uint256 j = i; j + 1 < chain.length; ++j) {
                    chain[j] = chain[j + 1];
                }
                chain.pop();
                break;
            }
        }
    }

    function doSetStatus(uint256 pSeed, uint8 raw) external {
        address p = _primary(pSeed);
        if (!registry.isRegistered(p)) return;
        // 1..3 -- never the None sentinel, which setStatus rejects by design.
        registry.setStatus(p, IREXRegistry.FundStatus(uint8(1 + (raw % 3))));
    }

    function doSetIssuer(uint256 pSeed, address issuer) external {
        address p = _primary(pSeed);
        if (!registry.isRegistered(p)) return;
        registry.setIssuer(p, _issuer(issuer));
    }
}
