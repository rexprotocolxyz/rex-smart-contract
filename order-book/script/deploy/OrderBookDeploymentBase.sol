// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Release tooling favors descriptive persisted keys and does not become production runtime bytecode.
// solhint-disable gas-small-strings

import {BPSOrderBookFeeController} from "../../contracts/BPSOrderBookFeeController.sol";
import {MAXIMUM_FEE_CONTROLLER_DELAY, MINIMUM_FEE_CONTROLLER_DELAY} from "../../contracts/FeeControllerDelayBounds.sol";
import {OrderBookDeployer} from "../../contracts/OrderBookDeployer.sol";
import {OrderBookFactory} from "../../contracts/OrderBookFactory.sol";
import {TakerFeeToken} from "../../contracts/interfaces/TakerFeeToken.sol";

interface VmOrderBookDeployment {
    function createDir(string calldata path, bool recursive) external;
    function envAddress(string calldata name) external returns (address value);
    function envOr(string calldata name, string calldata defaultValue) external returns (string memory value);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address value);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256 value);
    function projectRoot() external view returns (string memory path);
    function readFile(string calldata path) external view returns (string memory data);
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory json);
    function serializeBool(string calldata objectKey, string calldata valueKey, bool value)
        external
        returns (string memory json);
    function serializeBytes(string calldata objectKey, string calldata valueKey, bytes calldata value)
        external
        returns (string memory json);
    function serializeBytes32(string calldata objectKey, string calldata valueKey, bytes32 value)
        external
        returns (string memory json);
    function serializeString(string calldata objectKey, string calldata valueKey, string calldata value)
        external
        returns (string memory json);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory json);
    function startBroadcast(address broadcaster) external;
    function stopBroadcast() external;
    function writeJson(string calldata json, string calldata path) external;
}

abstract contract OrderBookDeploymentBase {
    // Lowercase `vm` follows Foundry's standard cheatcode naming convention.
    // slither-disable-next-line naming-convention
    VmOrderBookDeployment internal constant vm =
        VmOrderBookDeployment(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant CONFIGURATION_VERSION = 1;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct DeploymentConfig {
        uint256 configurationVersion;
        uint256 chainId;
        uint256 minimumDeploymentBlock;
        address factoryOwner;
        address defaultOrderBookOwner;
        address feeControllerProposer;
        address feeRecipient;
        uint16 initialMakerFeeBps;
        uint16 initialTakerFeeBps;
        uint16 controllerMaximumMakerFeeBps;
        uint16 controllerMaximumTakerFeeBps;
        uint16 orderBookMaximumMakerFeeBps;
        uint16 orderBookMaximumTakerFeeBps;
        TakerFeeToken initialTakerFeeToken;
        uint256 feeControllerDelay;
    }

    struct DeploymentAddresses {
        BPSOrderBookFeeController feeController;
        OrderBookDeployer orderBookDeployer;
        OrderBookFactory orderBookFactory;
    }

    error InvalidConfigurationVersion(uint256 actual, uint256 expected);
    error ConfigChainIdMismatch(uint256 configuredChainId, uint256 rpcChainId);
    error DeploymentBlockTooLow(uint256 currentBlock, uint256 minimumBlock);
    error InvalidAddress(bytes32 field, address value);
    error InvalidFeeConfiguration();
    error InvalidFeeControllerDelay(uint256 actual, uint256 minimum, uint256 maximum);
    error InvalidTakerFeeToken(uint256 value);
    error UnexpectedFeeControllerCodeHash(bytes32 expected, bytes32 actual);
    error UnexpectedOrderBookDeployerCodeHash(bytes32 expected, bytes32 actual);
    error UnexpectedOrderBookFactoryCodeHash(bytes32 expected, bytes32 actual);
    error DeploymentAssertionFailed(bytes32 assertion);

    function expectedOrderBookDeployerCodeHash() public pure returns (bytes32) {
        // Slither mistakes the compiler-provided runtime bytecode expression for a numeric literal.
        // slither-disable-next-line too-many-digits
        return keccak256(type(OrderBookDeployer).runtimeCode);
    }

    function _loadDeploymentConfig() internal returns (DeploymentConfig memory config, bytes32 configHash) {
        string memory defaultPath = string.concat(vm.projectRoot(), "/script/config/deployment.json");
        string memory path = vm.envOr("ORDER_BOOK_DEPLOYMENT_CONFIG", defaultPath);
        string memory json = vm.readFile(path);
        configHash = keccak256(bytes(json));

        config.configurationVersion = vm.parseJsonUint(json, ".configurationVersion");
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.minimumDeploymentBlock = vm.parseJsonUint(json, ".minimumDeploymentBlock");
        config.factoryOwner = vm.parseJsonAddress(json, ".factoryOwner");
        config.defaultOrderBookOwner = vm.parseJsonAddress(json, ".defaultOrderBookOwner");
        config.feeControllerProposer = vm.parseJsonAddress(json, ".feeControllerProposer");
        config.feeRecipient = vm.parseJsonAddress(json, ".feeRecipient");
        config.initialMakerFeeBps = _parseUint16(json, ".initialMakerFeeBps");
        config.initialTakerFeeBps = _parseUint16(json, ".initialTakerFeeBps");
        config.controllerMaximumMakerFeeBps = _parseUint16(json, ".controllerMaximumMakerFeeBps");
        config.controllerMaximumTakerFeeBps = _parseUint16(json, ".controllerMaximumTakerFeeBps");
        config.orderBookMaximumMakerFeeBps = _parseUint16(json, ".orderBookMaximumMakerFeeBps");
        config.orderBookMaximumTakerFeeBps = _parseUint16(json, ".orderBookMaximumTakerFeeBps");
        uint256 takerFeeToken = vm.parseJsonUint(json, ".initialTakerFeeToken");
        if (takerFeeToken > uint256(type(TakerFeeToken).max)) revert InvalidTakerFeeToken(takerFeeToken);
        config.initialTakerFeeToken = TakerFeeToken(takerFeeToken);
        config.feeControllerDelay = vm.parseJsonUint(json, ".feeControllerDelay");
    }

    function _validateDeploymentConfig(DeploymentConfig memory config) internal view {
        if (config.configurationVersion != CONFIGURATION_VERSION) {
            revert InvalidConfigurationVersion(config.configurationVersion, CONFIGURATION_VERSION);
        }
        if (config.chainId != block.chainid) revert ConfigChainIdMismatch(config.chainId, block.chainid);
        if (block.number < config.minimumDeploymentBlock) {
            revert DeploymentBlockTooLow(block.number, config.minimumDeploymentBlock);
        }
        _validateAddress("factoryOwner", config.factoryOwner);
        _validateAddress("defaultOrderBookOwner", config.defaultOrderBookOwner);
        _validateAddress("feeControllerProposer", config.feeControllerProposer);
        _validateAddress("feeRecipient", config.feeRecipient);
        _validateFees(config);
        if (
            config.feeControllerDelay < MINIMUM_FEE_CONTROLLER_DELAY
                || config.feeControllerDelay > MAXIMUM_FEE_CONTROLLER_DELAY
        ) {
            revert InvalidFeeControllerDelay(
                config.feeControllerDelay, MINIMUM_FEE_CONTROLLER_DELAY, MAXIMUM_FEE_CONTROLLER_DELAY
            );
        }
    }

    function _deploy(DeploymentConfig memory config) internal returns (DeploymentAddresses memory deployed) {
        deployed.feeController = new BPSOrderBookFeeController(
            config.initialMakerFeeBps,
            config.initialTakerFeeBps,
            config.controllerMaximumMakerFeeBps,
            config.controllerMaximumTakerFeeBps,
            config.initialTakerFeeToken,
            config.feeRecipient,
            config.feeControllerDelay,
            config.feeControllerProposer
        );
        deployed.orderBookFactory = new OrderBookFactory(
            config.factoryOwner,
            config.defaultOrderBookOwner,
            deployed.feeController,
            config.orderBookMaximumMakerFeeBps,
            config.orderBookMaximumTakerFeeBps
        );
        deployed.orderBookDeployer = OrderBookDeployer(address(deployed.orderBookFactory.orderBookDeployer()));
    }

    function _assertFreshDeployment(DeploymentConfig memory config, DeploymentAddresses memory deployed) internal {
        _assertInfrastructure(config, deployed);
        if (deployed.orderBookFactory.orderBookCount() != 0) _fail("canonicalMarketCount");
    }

    function _assertInfrastructure(DeploymentConfig memory config, DeploymentAddresses memory deployed) internal {
        _assertHasCode("feeControllerCode", address(deployed.feeController));
        _assertHasCode("orderBookDeployerCode", address(deployed.orderBookDeployer));
        _assertHasCode("orderBookFactoryCode", address(deployed.orderBookFactory));

        _assertReviewedFeeControllerRuntime(config, deployed.feeController);
        _assertOrderBookDeployer(deployed.orderBookDeployer);
        _assertReviewedFactoryRuntime(config, deployed);
        _assertFeeController(config, deployed.feeController);
        _assertFactory(config, deployed);
    }

    /// @dev A locally compiled reference binds verification to the reviewed controller implementation and constructor
    ///      configuration. The reference deployment is executed outside `startBroadcast`, so it is simulation-only.
    function _assertReviewedFeeControllerRuntime(DeploymentConfig memory config, BPSOrderBookFeeController controller)
        private
    {
        BPSOrderBookFeeController referenceController = new BPSOrderBookFeeController(
            config.initialMakerFeeBps,
            config.initialTakerFeeBps,
            config.controllerMaximumMakerFeeBps,
            config.controllerMaximumTakerFeeBps,
            config.initialTakerFeeToken,
            config.feeRecipient,
            config.feeControllerDelay,
            config.feeControllerProposer
        );
        bytes32 expectedCodeHash = address(referenceController).codehash;
        bytes32 actualCodeHash = address(controller).codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert UnexpectedFeeControllerCodeHash(expectedCodeHash, actualCodeHash);
        }
    }

    /// @dev Each factory creates a dedicated immutable deployer, so two reviewed factories have different raw runtime
    ///      hashes. Normalize only the compiler-injected 32-byte deployer words, then require every remaining byte to
    ///      match a locally compiled reference factory. Getter and state checks below remain separate assertions.
    function _assertReviewedFactoryRuntime(DeploymentConfig memory config, DeploymentAddresses memory deployed)
        private
    {
        OrderBookFactory referenceFactory = new OrderBookFactory(
            config.factoryOwner,
            config.defaultOrderBookOwner,
            deployed.feeController,
            config.orderBookMaximumMakerFeeBps,
            config.orderBookMaximumTakerFeeBps
        );
        bytes32 expectedCodeHash =
            _normalizedFactoryCodeHash(address(referenceFactory).code, address(referenceFactory.orderBookDeployer()));
        bytes32 actualCodeHash =
            _normalizedFactoryCodeHash(address(deployed.orderBookFactory).code, address(deployed.orderBookDeployer));
        if (actualCodeHash != expectedCodeHash) {
            revert UnexpectedOrderBookFactoryCodeHash(expectedCodeHash, actualCodeHash);
        }
    }

    function _normalizedFactoryCodeHash(bytes memory runtimeCode, address embeddedDeployer)
        private
        pure
        returns (bytes32)
    {
        bytes memory deployerWord = abi.encode(embeddedDeployer);
        uint256 length = runtimeCode.length;
        if (length < 32) return keccak256(runtimeCode);

        for (uint256 offset; offset <= length - 32; ++offset) {
            bool matches = true;
            for (uint256 i; i < 32; ++i) {
                if (runtimeCode[offset + i] == deployerWord[i]) continue;
                matches = false;
                break;
            }
            if (!matches) continue;

            for (uint256 i; i < 32; ++i) {
                runtimeCode[offset + i] = 0;
            }
            offset += 31;
        }
        return keccak256(runtimeCode);
    }

    function _assertOrderBookDeployer(OrderBookDeployer deployer) private view {
        bytes32 actualDeployerCodeHash = address(deployer).codehash;
        bytes32 expectedDeployerCodeHash = expectedOrderBookDeployerCodeHash();
        if (actualDeployerCodeHash != expectedDeployerCodeHash) {
            revert UnexpectedOrderBookDeployerCodeHash(expectedDeployerCodeHash, actualDeployerCodeHash);
        }
    }

    function _assertFeeController(DeploymentConfig memory config, BPSOrderBookFeeController controller) private view {
        if (controller.makerFeeBps() != config.initialMakerFeeBps) _fail("initialMakerFeeBps");
        if (controller.takerFeeBps() != config.initialTakerFeeBps) _fail("initialTakerFeeBps");
        if (controller.maximumMakerFeeBps() != config.controllerMaximumMakerFeeBps) {
            _fail("controllerMakerFeeCap");
        }
        if (controller.maximumTakerFeeBps() != config.controllerMaximumTakerFeeBps) {
            _fail("controllerTakerFeeCap");
        }
        if (controller.takerFeeToken() != config.initialTakerFeeToken) _fail("initialTakerFeeToken");
        if (controller.feeRecipient() != config.feeRecipient) _fail("feeRecipient");
        if (controller.getMinDelay() != config.feeControllerDelay) _fail("feeControllerDelay");
        _assertFeeControllerRoles(config.feeControllerProposer, controller);
    }

    function _assertFeeControllerRoles(address proposer, BPSOrderBookFeeController controller) private view {
        if (!controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(controller))) _fail("selfAdminRole");
        if (!controller.hasRole(controller.PROPOSER_ROLE(), proposer)) _fail("proposerRole");
        if (!controller.hasRole(controller.CANCELLER_ROLE(), proposer)) _fail("cancellerRole");
        if (!controller.hasRole(controller.EXECUTOR_ROLE(), address(0))) _fail("openExecutorRole");
        if (controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), proposer)) _fail("externalAdminRole");
    }

    function _assertFactory(DeploymentConfig memory config, DeploymentAddresses memory deployed) private view {
        BPSOrderBookFeeController controller = deployed.feeController;
        OrderBookFactory factory = deployed.orderBookFactory;
        if (factory.owner() != config.factoryOwner) _fail("factoryOwner");
        if (factory.pendingOwner() != address(0)) _fail("factoryPendingOwner");
        if (factory.defaultOrderBookOwner() != config.defaultOrderBookOwner) _fail("defaultOrderBookOwner");
        if (address(factory.defaultFeeController()) != address(controller)) _fail("defaultFeeController");
        if (factory.maximumMakerFeeBps() != config.orderBookMaximumMakerFeeBps) _fail("orderBookMakerFeeCap");
        if (factory.maximumTakerFeeBps() != config.orderBookMaximumTakerFeeBps) _fail("orderBookTakerFeeCap");
        if (address(factory.orderBookDeployer()) != address(deployed.orderBookDeployer)) _fail("orderBookDeployer");
    }

    function _writeSimulationArtifact(
        DeploymentConfig memory config,
        bytes32 configHash,
        address broadcaster,
        DeploymentAddresses memory deployed
    ) internal {
        string memory defaultPath = string.concat(vm.projectRoot(), "/simulations/latest.json");
        string memory outputPath = vm.envOr("ORDER_BOOK_SIMULATION_OUTPUT", defaultPath);
        vm.createDir(string.concat(vm.projectRoot(), "/simulations"), true);

        string memory objectKey = "orderBookSimulation";
        // Foundry serializers accumulate fields under objectKey; only the final returned JSON is persisted.
        // slither-disable-start unused-return
        vm.serializeString(objectKey, "artifactType", "SIMULATION");
        vm.serializeBool(objectKey, "broadcastConfirmed", false);
        vm.serializeUint(objectKey, "configurationVersion", config.configurationVersion);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeUint(objectKey, "minimumDeploymentBlock", config.minimumDeploymentBlock);
        vm.serializeUint(objectKey, "observedBlockNumber", block.number);
        vm.serializeBytes32(objectKey, "configurationHash", configHash);
        vm.serializeAddress(objectKey, "broadcaster", broadcaster);
        vm.serializeAddress(objectKey, "feeController", address(deployed.feeController));
        vm.serializeAddress(objectKey, "orderBookDeployer", address(deployed.orderBookDeployer));
        vm.serializeAddress(objectKey, "orderBookFactory", address(deployed.orderBookFactory));
        vm.serializeBytes32(objectKey, "feeControllerCodeHash", address(deployed.feeController).codehash);
        vm.serializeBytes32(objectKey, "orderBookDeployerCodeHash", address(deployed.orderBookDeployer).codehash);
        vm.serializeBytes32(objectKey, "orderBookFactoryCodeHash", address(deployed.orderBookFactory).codehash);
        _serializeConstructorArguments(objectKey, config, deployed);
        vm.serializeUint(objectKey, "canonicalMarketCount", 0);
        // slither-disable-end unused-return
        string memory json = vm.serializeString(objectKey, "result", "SIMULATION_ONLY");
        vm.writeJson(json, outputPath);
    }

    function _serializeConstructorArguments(
        string memory objectKey,
        DeploymentConfig memory config,
        DeploymentAddresses memory deployed
    ) private {
        // These serializer calls intentionally update the same in-memory cheatcode object used by the caller.
        // slither-disable-start unused-return
        vm.serializeBytes(
            objectKey,
            "feeControllerConstructorArguments",
            abi.encode(
                config.initialMakerFeeBps,
                config.initialTakerFeeBps,
                config.controllerMaximumMakerFeeBps,
                config.controllerMaximumTakerFeeBps,
                config.initialTakerFeeToken,
                config.feeRecipient,
                config.feeControllerDelay,
                config.feeControllerProposer
            )
        );
        vm.serializeBytes(objectKey, "orderBookDeployerConstructorArguments", bytes(""));
        vm.serializeBytes(
            objectKey,
            "orderBookFactoryConstructorArguments",
            abi.encode(
                config.factoryOwner,
                config.defaultOrderBookOwner,
                deployed.feeController,
                config.orderBookMaximumMakerFeeBps,
                config.orderBookMaximumTakerFeeBps
            )
        );
        // slither-disable-end unused-return
    }

    function _validateFees(DeploymentConfig memory config) private pure {
        if (
            config.controllerMaximumMakerFeeBps >= BPS_DENOMINATOR
                || config.controllerMaximumTakerFeeBps >= BPS_DENOMINATOR
                || config.orderBookMaximumMakerFeeBps >= BPS_DENOMINATOR
                || config.orderBookMaximumTakerFeeBps >= BPS_DENOMINATOR
                || config.initialMakerFeeBps > config.controllerMaximumMakerFeeBps
                || config.initialTakerFeeBps > config.controllerMaximumTakerFeeBps
                || config.controllerMaximumMakerFeeBps > config.orderBookMaximumMakerFeeBps
                || config.controllerMaximumTakerFeeBps > config.orderBookMaximumTakerFeeBps
                || uint256(config.initialMakerFeeBps) + config.initialTakerFeeBps > BPS_DENOMINATOR
        ) {
            revert InvalidFeeConfiguration();
        }
    }

    function _validateAddress(bytes32 field, address account) internal pure {
        if (account == address(0)) revert InvalidAddress(field, account);
    }

    function _parseUint16(string memory json, string memory key) private pure returns (uint16 parsed) {
        uint256 value = vm.parseJsonUint(json, key);
        if (value > type(uint16).max) revert InvalidFeeConfiguration();
        // The preceding bound guarantees this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        parsed = uint16(value);
    }

    function _assertHasCode(bytes32 assertion, address account) private view {
        if (account.code.length == 0) _fail(assertion);
    }

    function _fail(bytes32 assertion) internal pure {
        revert DeploymentAssertionFailed(assertion);
    }
}
