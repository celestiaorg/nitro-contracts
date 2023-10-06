// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "./util/TestUtil.sol";
import "../../src/rollup/BridgeCreator.sol";
import "../../src/bridge/ISequencerInbox.sol";
import "../../src/bridge/AbsInbox.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract BridgeCreatorTest is Test {
    BridgeCreator public creator;
    address public owner = address(100);

    uint256 public constant MAX_DATA_SIZE = 117_964;

    function setUp() public {
        BridgeCreator.BridgeContracts memory ethBasedTemplates = BridgeCreator.BridgeContracts({
            bridge: IBridge(new Bridge()),
            sequencerInbox: ISequencerInbox(new SequencerInbox(MAX_DATA_SIZE)),
            inbox: IInboxBase(new Inbox(MAX_DATA_SIZE)),
            rollupEventInbox: IRollupEventInbox(new RollupEventInbox()),
            outbox: IOutbox(new Outbox())
        });

        BridgeCreator.BridgeContracts memory erc20BasedTemplates = BridgeCreator.BridgeContracts({
            bridge: IBridge(new ERC20Bridge()),
            sequencerInbox: ISequencerInbox(new SequencerInbox(MAX_DATA_SIZE)),
            inbox: IInboxBase(new ERC20Inbox(MAX_DATA_SIZE)),
            rollupEventInbox: IRollupEventInbox(new ERC20RollupEventInbox()),
            outbox: IOutbox(new ERC20Outbox())
        });
        vm.prank(owner);
        creator = new BridgeCreator(ethBasedTemplates, erc20BasedTemplates);
    }

    /* solhint-disable func-name-mixedcase */
    function test_constructor() public {
        (
            IBridge bridgeTemplate,
            ISequencerInbox sequencerInboxTemplate,
            IInboxBase inboxTemplate,
            IRollupEventInbox rollupEventInboxTemplate,
            IOutbox outboxTemplate
        ) = creator.ethBasedTemplates();
        assertTrue(address(bridgeTemplate) != address(0), "Bridge not created");
        assertTrue(address(sequencerInboxTemplate) != address(0), "SeqInbox not created");
        assertTrue(address(inboxTemplate) != address(0), "Inbox not created");
        assertTrue(address(rollupEventInboxTemplate) != address(0), "Event inbox not created");
        assertTrue(address(outboxTemplate) != address(0), "Outbox not created");

        (
            IBridge erc20BridgeTemplate,
            ISequencerInbox erc20SequencerInboxTemplate,
            IInboxBase erc20InboxTemplate,
            IRollupEventInbox erc20RollupEventInboxTemplate,
            IOutbox erc20OutboxTemplate
        ) = creator.erc20BasedTemplates();
        assertTrue(address(erc20BridgeTemplate) != address(0), "Bridge not created");
        assertTrue(address(erc20SequencerInboxTemplate) != address(0), "SeqInbox not created");
        assertTrue(address(erc20InboxTemplate) != address(0), "Inbox not created");
        assertTrue(address(erc20RollupEventInboxTemplate) != address(0), "Event inbox not created");
        assertTrue(address(erc20OutboxTemplate) != address(0), "Outbox not created");
    }

    function test_updateTemplates() public {
        BridgeCreator.BridgeContracts memory templs = BridgeCreator.BridgeContracts({
            bridge: IBridge(address(200)),
            sequencerInbox: ISequencerInbox(address(201)),
            inbox: IInboxBase(address(202)),
            rollupEventInbox: IRollupEventInbox(address(203)),
            outbox: IOutbox(address(204))
        });

        vm.prank(owner);
        creator.updateTemplates(templs);

        (
            IBridge bridgeTemplate,
            ISequencerInbox sequencerInboxTemplate,
            IInboxBase inboxTemplate,
            IRollupEventInbox rollupEventInboxTemplate,
            IOutbox outboxTemplate
        ) = creator.ethBasedTemplates();
        assertEq(address(bridgeTemplate), address(templs.bridge), "Invalid bridge");
        assertEq(
            address(sequencerInboxTemplate), address(templs.sequencerInbox), "Invalid seqInbox"
        );
        assertEq(address(inboxTemplate), address(templs.inbox), "Invalid inbox");
        assertEq(
            address(rollupEventInboxTemplate),
            address(templs.rollupEventInbox),
            "Invalid rollup event inbox"
        );
        assertEq(address(outboxTemplate), address(templs.outbox), "Invalid outbox");
    }

    function test_updateERC20Templates() public {
        BridgeCreator.BridgeContracts memory templs = BridgeCreator.BridgeContracts({
            bridge: ERC20Bridge(address(400)),
            sequencerInbox: SequencerInbox(address(401)),
            inbox: ERC20Inbox(address(402)),
            rollupEventInbox: ERC20RollupEventInbox(address(403)),
            outbox: ERC20Outbox(address(404))
        });

        vm.prank(owner);
        creator.updateERC20Templates(templs);

        (
            IBridge bridgeTemplate,
            ISequencerInbox sequencerInboxTemplate,
            IInboxBase inboxTemplate,
            IRollupEventInbox rollupEventInboxTemplate,
            IOutbox outboxTemplate
        ) = creator.erc20BasedTemplates();
        assertEq(address(bridgeTemplate), address(templs.bridge), "Invalid bridge");
        assertEq(
            address(sequencerInboxTemplate), address(templs.sequencerInbox), "Invalid seqInbox"
        );
        assertEq(address(inboxTemplate), address(templs.inbox), "Invalid inbox");
        assertEq(
            address(rollupEventInboxTemplate),
            address(templs.rollupEventInbox),
            "Invalid rollup event inbox"
        );
        assertEq(address(outboxTemplate), address(templs.outbox), "Invalid outbox");
    }

    function test_createEthBridge() public {
        address proxyAdmin = address(300);
        address rollup = address(301);
        address nativeToken = address(0);
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(10, 20, 30, 40);
        timeVars.delayBlocks;

        (
            IBridge bridge,
            ISequencerInbox seqInbox,
            IInboxBase inbox,
            IRollupEventInbox eventInbox,
            IOutbox outbox
        ) = creator.createBridge(proxyAdmin, rollup, nativeToken, timeVars);

        // bridge
        assertEq(address(bridge.rollup()), rollup, "Invalid rollup ref");
        assertEq(bridge.activeOutbox(), address(0), "Invalid activeOutbox ref");

        // seqInbox
        assertEq(address(seqInbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(seqInbox.rollup()), rollup, "Invalid rollup ref");
        (uint256 _delayBlocks, uint256 _futureBlocks, uint256 _delaySeconds, uint256 _futureSeconds)
        = seqInbox.maxTimeVariation();
        assertEq(_delayBlocks, timeVars.delayBlocks, "Invalid delayBlocks");
        assertEq(_futureBlocks, timeVars.futureBlocks, "Invalid futureBlocks");
        assertEq(_delaySeconds, timeVars.delaySeconds, "Invalid delaySeconds");
        assertEq(_futureSeconds, timeVars.futureSeconds, "Invalid futureSeconds");

        // inbox
        assertEq(address(inbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(inbox.sequencerInbox()), address(seqInbox), "Invalid seqInbox ref");
        assertEq(inbox.allowListEnabled(), false, "Invalid allowListEnabled");
        assertEq(AbsInbox(address(inbox)).paused(), false, "Invalid paused status");

        // rollup event inbox
        assertEq(address(eventInbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(eventInbox.rollup()), rollup, "Invalid rollup ref");

        // outbox
        assertEq(address(outbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(outbox.rollup()), rollup, "Invalid rollup ref");

        // revert fetching native token
        vm.expectRevert();
        IERC20Bridge(address(bridge)).nativeToken();
    }

    function test_createERC20Bridge() public {
        address proxyAdmin = address(300);
        address rollup = address(301);
        address nativeToken =
            address(new ERC20PresetFixedSupply("Appchain Token", "App", 1_000_000, address(this)));
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(10, 20, 30, 40);
        timeVars.delayBlocks;

        (
            IBridge bridge,
            ISequencerInbox seqInbox,
            IInboxBase inbox,
            IRollupEventInbox eventInbox,
            IOutbox outbox
        ) = creator.createBridge(proxyAdmin, rollup, nativeToken, timeVars);

        // bridge
        assertEq(address(bridge.rollup()), rollup, "Invalid rollup ref");
        assertEq(
            address(IERC20Bridge(address(bridge)).nativeToken()),
            nativeToken,
            "Invalid nativeToken ref"
        );
        assertEq(bridge.activeOutbox(), address(0), "Invalid activeOutbox ref");

        // seqInbox
        assertEq(address(seqInbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(seqInbox.rollup()), rollup, "Invalid rollup ref");
        (uint256 _delayBlocks, uint256 _futureBlocks, uint256 _delaySeconds, uint256 _futureSeconds)
        = seqInbox.maxTimeVariation();
        assertEq(_delayBlocks, timeVars.delayBlocks, "Invalid delayBlocks");
        assertEq(_futureBlocks, timeVars.futureBlocks, "Invalid futureBlocks");
        assertEq(_delaySeconds, timeVars.delaySeconds, "Invalid delaySeconds");
        assertEq(_futureSeconds, timeVars.futureSeconds, "Invalid futureSeconds");

        // inbox
        assertEq(address(inbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(inbox.sequencerInbox()), address(seqInbox), "Invalid seqInbox ref");
        assertEq(inbox.allowListEnabled(), false, "Invalid allowListEnabled");
        assertEq(AbsInbox(address(inbox)).paused(), false, "Invalid paused status");

        // rollup event inbox
        assertEq(address(eventInbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(eventInbox.rollup()), rollup, "Invalid rollup ref");

        // outbox
        assertEq(address(outbox.bridge()), address(bridge), "Invalid bridge ref");
        assertEq(address(outbox.rollup()), rollup, "Invalid rollup ref");
    }
}
