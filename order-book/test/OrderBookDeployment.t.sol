// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {OrderBookDeployer} from "../contracts/OrderBookDeployer.sol";
import {OrderBookFactory} from "../contracts/OrderBookFactory.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {DeployOrderBookSystem} from "../script/deploy/DeployOrderBookSystem.s.sol";
import {OrderBookDeploymentBase} from "../script/deploy/OrderBookDeploymentBase.sol";

interface VmOrderBookDeploymentTest {
    function chainId(uint256 newChainId) external;
    function createDir(string calldata path, bool recursive) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 selector) external;
    function expectPartialRevert(bytes4 selector) external;
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address value);
    function parseJsonBool(string calldata json, string calldata key) external pure returns (bool value);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32 value);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory value);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256 value);
    function projectRoot() external view returns (string memory path);
    function readFile(string calldata path) external view returns (string memory data);
    function removeFile(string calldata path) external;
    function roll(uint256 newHeight) external;
    function serializeAddress(string calldata objectKey, string calldata valueKey, address value)
        external
        returns (string memory json);
    function serializeUint(string calldata objectKey, string calldata valueKey, uint256 value)
        external
        returns (string memory json);
    function setEnv(string calldata name, string calldata value) external;
    function writeJson(string calldata json, string calldata path) external;
}

contract OrderBookDeploymentHarness is OrderBookDeploymentBase {
    function validate(DeploymentConfig calldata config) external view {
        _validateDeploymentConfig(config);
    }

    function deployAndAssert(DeploymentConfig calldata config) external returns (DeploymentAddresses memory deployed) {
        _validateDeploymentConfig(config);
        deployed = _deploy(config);
        _assertFreshDeployment(config, deployed);
    }

    function assertDeployerIdentity(address candidate) external view {
        DeploymentAddresses memory deployed;
        deployed.orderBookDeployer = OrderBookDeployer(candidate);
        bytes32 expected = expectedOrderBookDeployerCodeHash();
        bytes32 actual = candidate.codehash;
        if (actual != expected) revert UnexpectedOrderBookDeployerCodeHash(expected, actual);
    }

    function assertInfrastructure(DeploymentConfig calldata config, DeploymentAddresses calldata deployed) external {
        _assertInfrastructure(config, deployed);
    }
}

/// @dev Deliberately getter-compatible with the reviewed controller while carrying different runtime bytecode.
contract MockCounterfeitFeeController is BPSOrderBookFeeController {
    constructor(
        uint16 initialMakerFeeBps,
        uint16 initialTakerFeeBps,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps,
        TakerFeeToken initialTakerFeeToken,
        address initialFeeRecipient,
        uint256 minimumDelay,
        address proposer
    )
        BPSOrderBookFeeController(
            initialMakerFeeBps,
            initialTakerFeeBps,
            maximumMakerFeeBps,
            maximumTakerFeeBps,
            initialTakerFeeToken,
            initialFeeRecipient,
            minimumDelay,
            proposer
        )
    {}

    function counterfeitMarker() external pure returns (bool) {
        return true;
    }
}

/// @dev Deliberately getter-compatible with the reviewed factory while carrying different runtime bytecode.
contract MockCounterfeitOrderBookFactory is OrderBookFactory {
    constructor(
        address initialOwner,
        address defaultOrderBookOwner,
        BPSOrderBookFeeController defaultFeeController,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    )
        OrderBookFactory(
            initialOwner, defaultOrderBookOwner, defaultFeeController, maximumMakerFeeBps, maximumTakerFeeBps
        )
    {}

    function counterfeitMarker() external pure returns (bool) {
        return true;
    }
}

contract OrderBookDeploymentTest {
    VmOrderBookDeploymentTest private constant vm =
        VmOrderBookDeploymentTest(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    bytes32 private constant FACTORY_OWNER_FIELD = "factoryOwner";
    bytes32 private constant FEE_RECIPIENT_FIELD = "feeRecipient";

    OrderBookDeploymentHarness private harness;

    function setUp() public {
        vm.chainId(ANVIL_CHAIN_ID);
        vm.roll(100);
        harness = new OrderBookDeploymentHarness();
    }

    function testDeploysInReviewedOrderAndAssertsFinalConfiguration() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        OrderBookDeploymentBase.DeploymentAddresses memory deployed = harness.deployAndAssert(config);

        require(address(deployed.feeController).code.length != 0, "controller missing");
        require(address(deployed.orderBookDeployer).code.length != 0, "deployer missing");
        require(address(deployed.orderBookFactory).code.length != 0, "factory missing");
        require(
            address(deployed.orderBookDeployer).codehash == harness.expectedOrderBookDeployerCodeHash(),
            "deployer bytecode mismatch"
        );
        require(deployed.orderBookFactory.owner() == address(this), "factory owner mismatch");
        require(deployed.orderBookFactory.orderBookCount() == 0, "unexpected canonical market");
        require(
            deployed.feeController.hasRole(deployed.feeController.PROPOSER_ROLE(), address(this)),
            "proposer role missing"
        );
    }

    function testRunsJsonDrivenSimulationAndWritesNonAuthoritativeArtifact() public {
        string memory projectRoot = vm.projectRoot();
        string memory configPath = string.concat(projectRoot, "/simulations/test-deployment-config.json");
        string memory simulationPath = string.concat(projectRoot, "/simulations/test-simulation-output.json");
        vm.createDir(string.concat(projectRoot, "/simulations"), true);
        _writeConfig(configPath);

        vm.setEnv("ORDER_BOOK_DEPLOYMENT_CONFIG", configPath);
        vm.setEnv("ORDER_BOOK_SIMULATION_OUTPUT", simulationPath);
        vm.setEnv("DEPLOYER_ADDRESS", "0x000000000000000000000000000000000000bEEF");

        DeployOrderBookSystem deployScript = new DeployOrderBookSystem();
        deployScript.run();
        string memory simulationJson = vm.readFile(simulationPath);
        address factoryAddress = vm.parseJsonAddress(simulationJson, ".orderBookFactory");
        require(factoryAddress.code.length != 0, "simulation factory missing");
        require(vm.parseJsonBytes32(simulationJson, ".configurationHash") != bytes32(0), "config hash missing");
        require(
            keccak256(bytes(vm.parseJsonString(simulationJson, ".artifactType"))) == keccak256("SIMULATION"),
            "wrong artifact type"
        );
        require(
            keccak256(bytes(vm.parseJsonString(simulationJson, ".result"))) == keccak256("SIMULATION_ONLY"),
            "simulation claims deployment success"
        );
        require(!vm.parseJsonBool(simulationJson, ".broadcastConfirmed"), "simulation claims broadcast confirmation");
        require(
            vm.parseJsonAddress(simulationJson, ".broadcaster") == address(0x000000000000000000000000000000000000bEEF),
            "broadcaster mismatch"
        );

        vm.removeFile(configPath);
        vm.removeFile(simulationPath);
    }

    function testRejectsConfigurationForAnotherChainAndPrematureBlock() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        config.chainId = 1;
        vm.expectRevert(
            abi.encodeWithSelector(OrderBookDeploymentBase.ConfigChainIdMismatch.selector, 1, ANVIL_CHAIN_ID)
        );
        harness.validate(config);

        config = _validConfig();
        config.minimumDeploymentBlock = block.number + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderBookDeploymentBase.DeploymentBlockTooLow.selector, block.number, config.minimumDeploymentBlock
            )
        );
        harness.validate(config);
    }

    function testRejectsInvalidConfigurationVersion() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        config.configurationVersion = 2;
        vm.expectRevert(abi.encodeWithSelector(OrderBookDeploymentBase.InvalidConfigurationVersion.selector, 2, 1));
        harness.validate(config);
    }

    function testAcceptsEoaPrivilegedRolesAndRejectsZeroRole() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        config.factoryOwner = address(0xA11CE);
        config.defaultOrderBookOwner = address(0xB0B);
        config.feeControllerProposer = address(0xCAFE);
        harness.validate(config);

        config = _validConfig();
        config.factoryOwner = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderBookDeploymentBase.InvalidAddress.selector, FACTORY_OWNER_FIELD, config.factoryOwner
            )
        );
        harness.validate(config);
    }

    function testAcceptsEoaFeeRecipientAndRejectsZeroRecipient() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        config.feeRecipient = address(0xFEE);
        harness.validate(config);

        config.feeRecipient = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderBookDeploymentBase.InvalidAddress.selector, FEE_RECIPIENT_FIELD, config.feeRecipient
            )
        );
        harness.validate(config);
    }

    function testRejectsUnsafeFeeCapsAndControllerDelay() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        config.controllerMaximumTakerFeeBps = config.orderBookMaximumTakerFeeBps + 1;
        vm.expectRevert(OrderBookDeploymentBase.InvalidFeeConfiguration.selector);
        harness.validate(config);

        config = _validConfig();
        config.initialMakerFeeBps = config.controllerMaximumMakerFeeBps + 1;
        vm.expectRevert(OrderBookDeploymentBase.InvalidFeeConfiguration.selector);
        harness.validate(config);

        config = _validConfig();
        config.feeControllerDelay = 1 days - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderBookDeploymentBase.InvalidFeeControllerDelay.selector, config.feeControllerDelay, 1 days, 30 days
            )
        );
        harness.validate(config);
    }

    function testRejectsDifferentOrderBookDeployerRuntime() public {
        address wrongRuntime = address(harness);
        bytes32 expected = harness.expectedOrderBookDeployerCodeHash();
        bytes32 actual = wrongRuntime.codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderBookDeploymentBase.UnexpectedOrderBookDeployerCodeHash.selector, expected, actual
            )
        );
        harness.assertDeployerIdentity(wrongRuntime);
    }

    function testRejectsGetterCompatibleCounterfeitFeeControllerRuntime() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        MockCounterfeitFeeController counterfeit = new MockCounterfeitFeeController(
            config.initialMakerFeeBps,
            config.initialTakerFeeBps,
            config.controllerMaximumMakerFeeBps,
            config.controllerMaximumTakerFeeBps,
            config.initialTakerFeeToken,
            config.feeRecipient,
            config.feeControllerDelay,
            config.feeControllerProposer
        );
        OrderBookFactory factory = new OrderBookFactory(
            config.factoryOwner,
            config.defaultOrderBookOwner,
            counterfeit,
            config.orderBookMaximumMakerFeeBps,
            config.orderBookMaximumTakerFeeBps
        );
        OrderBookDeploymentBase.DeploymentAddresses memory deployed = OrderBookDeploymentBase.DeploymentAddresses({
            feeController: BPSOrderBookFeeController(payable(address(counterfeit))),
            orderBookDeployer: OrderBookDeployer(address(factory.orderBookDeployer())),
            orderBookFactory: factory
        });

        require(counterfeit.makerFeeBps() == config.initialMakerFeeBps, "counterfeit maker fee mismatch");
        require(counterfeit.feeRecipient() == config.feeRecipient, "counterfeit recipient mismatch");
        vm.expectPartialRevert(OrderBookDeploymentBase.UnexpectedFeeControllerCodeHash.selector);
        harness.assertInfrastructure(config, deployed);
    }

    function testRejectsGetterCompatibleCounterfeitFactoryRuntime() public {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        BPSOrderBookFeeController controller = _deployFeeController(config);
        MockCounterfeitOrderBookFactory counterfeit = new MockCounterfeitOrderBookFactory(
            config.factoryOwner,
            config.defaultOrderBookOwner,
            controller,
            config.orderBookMaximumMakerFeeBps,
            config.orderBookMaximumTakerFeeBps
        );
        OrderBookDeploymentBase.DeploymentAddresses memory deployed = OrderBookDeploymentBase.DeploymentAddresses({
            feeController: controller,
            orderBookDeployer: OrderBookDeployer(address(counterfeit.orderBookDeployer())),
            orderBookFactory: OrderBookFactory(address(counterfeit))
        });

        require(counterfeit.owner() == config.factoryOwner, "counterfeit owner mismatch");
        require(address(counterfeit.defaultFeeController()) == address(controller), "counterfeit controller mismatch");
        vm.expectPartialRevert(OrderBookDeploymentBase.UnexpectedOrderBookFactoryCodeHash.selector);
        harness.assertInfrastructure(config, deployed);
    }

    function _validConfig() private view returns (OrderBookDeploymentBase.DeploymentConfig memory config) {
        config.configurationVersion = 1;
        config.chainId = ANVIL_CHAIN_ID;
        config.minimumDeploymentBlock = 0;
        config.factoryOwner = address(this);
        config.defaultOrderBookOwner = address(this);
        config.feeControllerProposer = address(this);
        config.feeRecipient = address(0xFEE);
        config.initialMakerFeeBps = 10;
        config.initialTakerFeeBps = 20;
        config.controllerMaximumMakerFeeBps = 100;
        config.controllerMaximumTakerFeeBps = 200;
        config.orderBookMaximumMakerFeeBps = 150;
        config.orderBookMaximumTakerFeeBps = 250;
        config.initialTakerFeeToken = TakerFeeToken.QUOTE;
        config.feeControllerDelay = 2 days;
    }

    function _deployFeeController(OrderBookDeploymentBase.DeploymentConfig memory config)
        private
        returns (BPSOrderBookFeeController controller)
    {
        controller = new BPSOrderBookFeeController(
            config.initialMakerFeeBps,
            config.initialTakerFeeBps,
            config.controllerMaximumMakerFeeBps,
            config.controllerMaximumTakerFeeBps,
            config.initialTakerFeeToken,
            config.feeRecipient,
            config.feeControllerDelay,
            config.feeControllerProposer
        );
    }

    function _writeConfig(string memory path) private {
        OrderBookDeploymentBase.DeploymentConfig memory config = _validConfig();
        string memory objectKey = "deploymentIntegrationConfig";
        vm.serializeUint(objectKey, "configurationVersion", config.configurationVersion);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeUint(objectKey, "minimumDeploymentBlock", config.minimumDeploymentBlock);
        vm.serializeAddress(objectKey, "factoryOwner", config.factoryOwner);
        vm.serializeAddress(objectKey, "defaultOrderBookOwner", config.defaultOrderBookOwner);
        vm.serializeAddress(objectKey, "feeControllerProposer", config.feeControllerProposer);
        vm.serializeAddress(objectKey, "feeRecipient", config.feeRecipient);
        vm.serializeUint(objectKey, "initialMakerFeeBps", config.initialMakerFeeBps);
        vm.serializeUint(objectKey, "initialTakerFeeBps", config.initialTakerFeeBps);
        vm.serializeUint(objectKey, "controllerMaximumMakerFeeBps", config.controllerMaximumMakerFeeBps);
        vm.serializeUint(objectKey, "controllerMaximumTakerFeeBps", config.controllerMaximumTakerFeeBps);
        vm.serializeUint(objectKey, "orderBookMaximumMakerFeeBps", config.orderBookMaximumMakerFeeBps);
        vm.serializeUint(objectKey, "orderBookMaximumTakerFeeBps", config.orderBookMaximumTakerFeeBps);
        vm.serializeUint(objectKey, "initialTakerFeeToken", uint256(config.initialTakerFeeToken));
        string memory json = vm.serializeUint(objectKey, "feeControllerDelay", config.feeControllerDelay);
        vm.writeJson(json, path);
    }
}
