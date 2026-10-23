"""Explicit immutable runtime selection; no game/debugger access."""
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import replay_trial as r

TRIAL=Path(os.environ['BG3_REPLAY_TEST_TRIAL']) if os.environ.get('BG3_REPLAY_TEST_TRIAL') else None
PROFILE=Path(os.environ['BG3_REPLAY_TEST_PROFILE']) if os.environ.get('BG3_REPLAY_TEST_PROFILE') else None
ADAPTER=Path(os.environ['BG3_REPLAY_TEST_V206_ADAPTER']) if os.environ.get('BG3_REPLAY_TEST_V206_ADAPTER') else None
V206_SHA='c7e3e92494402b4a86f705cf6525d8cf53c4e77384db1027d741d5b47adcf054'

class RuntimeSelectionUnit(unittest.TestCase):
    def test_default_remains_pinned_and_explicit_path_is_resolved(self):
        bridge,selection=r.runtime_selection()
        self.assertEqual(selection['expectedSimulatorSha256'],r.SIMULATOR_SHA)
        self.assertEqual(selection['selection'],'default-pinned')
        explicit,selection=r.runtime_selection(Path('specific/TrialReplay.dll'))
        self.assertEqual(explicit,Path('specific/TrialReplay.dll').resolve())
        self.assertEqual(selection['expectedSimulatorSha256'],r.SIMULATOR_SHA)
    def test_hash_requires_explicit_adapter_and_canonical_hash(self):
        with self.assertRaisesRegex(r.Refusal,'requires --adapter'):r.runtime_selection(None,V206_SHA)
        for bad in ('','f'*63,'f'*65,'G'*64,'A'*64,123,False):
            with self.subTest(value=bad),self.assertRaisesRegex(r.Refusal,'64 lowercase hex'):
                r.runtime_selection(Path('explicit.dll'),bad)
    def test_prelaunch_hash_uses_explicit_expected_value(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge=Path(directory)/'TrialReplay.dll';bridge.write_bytes(b'bridge')
            simulator=bridge.with_name('bg3sim.dll');simulator.write_bytes(b'explicit selected bytes')
            wanted=r.sha(simulator.read_bytes())
            with patch.object(r.subprocess,'run',side_effect=AssertionError('must never launch here')):
                receipt=r.verify_bridge(bridge,wanted)
                self.assertEqual(receipt['simulatorSha256'],wanted)
                with self.assertRaisesRegex(r.Refusal,'hash mismatch'):r.verify_bridge(bridge,r.SIMULATOR_SHA)
    def test_cli_threads_explicit_options_to_run(self):
        argv=['replay_trial.py','trial','--output','new-output','--adapter','chosen/TrialReplay.dll','--simulator-sha256',V206_SHA]
        with patch.object(r.sys,'argv',argv),patch.object(r,'run',return_value={'status':'refused','engineInvoked':False}) as run,patch.object(r.sys,'stdout',new_callable=io.StringIO):
            self.assertEqual(r.main(),2)
        self.assertEqual(run.call_args.kwargs,{'adapter_path':Path('chosen/TrialReplay.dll'),'simulator_sha256':V206_SHA})

@unittest.skipUnless(TRIAL and PROFILE and ADAPTER,'Set BG3_REPLAY_TEST_TRIAL, BG3_REPLAY_TEST_PROFILE and BG3_REPLAY_TEST_V206_ADAPTER for paired real API controls')
class PairedRuntimeIntegration(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
    def test_explicit_v206_and_default_have_identical_mechanics(self):
        old=r.run(TRIAL,PROFILE,self.root/'old')
        new=r.run(TRIAL,PROFILE,self.root/'new',adapter_path=ADAPTER,simulator_sha256=V206_SHA)
        before=json.loads((self.root/'old/operands.json').read_bytes());after=json.loads((self.root/'new/operands.json').read_bytes())
        self.assertEqual(before.pop('simulatorSha256'),r.SIMULATOR_SHA)
        self.assertEqual(after.pop('simulatorSha256'),V206_SHA)
        self.assertEqual(before,after)
        left=json.loads((self.root/'old/adapter.stdout.json').read_bytes());right=json.loads((self.root/'new/adapter.stdout.json').read_bytes())
        self.assertEqual(left['compiledAbility'],right['compiledAbility'])
        self.assertEqual(left['result'],right['result'])
        self.assertEqual(old['comparison'],new['comparison'])
        self.assertEqual(new['mismatches'],[])
        self.assertEqual(len(new['knownProjectionExclusions']),2)
        self.assertEqual(new['prelaunchBridgeReceipt']['simulatorSha256'],V206_SHA)
        self.assertEqual(new['qualification']['runtimeSelection']['expectedSimulatorSha256'],V206_SHA)
        self.assertEqual(r.SIMULATOR_SHA,'94f7ef46cd62dd698df08a986f5b99e6fbda804ad1b61a00ce6d7768e0de9bba')
    def test_wrong_expected_reference_refuses_without_process_launch(self):
        with patch.object(r.subprocess,'run',side_effect=AssertionError('must not launch')):
            with self.assertRaisesRegex(r.Refusal,'hash mismatch'):
                r.run(TRIAL,PROFILE,self.root/'bad-pin',adapter_path=ADAPTER,simulator_sha256='0'*64)
    def test_loaded_assembly_receipt_must_match_selected_pin(self):
        # Retain real execution; corrupt only the returned receipt after process completion.
        original=r.subprocess.run
        def wrong_receipt(*args,**kwargs):
            completed=original(*args,**kwargs)
            value=json.loads(completed.stdout);value['simulatorSha256']=r.SIMULATOR_SHA
            changed=copy.copy(completed);changed.stdout=json.dumps(value);return changed
        with patch.object(r.subprocess,'run',side_effect=wrong_receipt),self.assertRaisesRegex(r.Refusal,'API execution receipt mismatch'):
            r.run(TRIAL,PROFILE,self.root/'wrong-receipt',adapter_path=ADAPTER,simulator_sha256=V206_SHA)
    def test_strict_still_refuses_without_launching_selected_runtime(self):
        with patch.object(r.subprocess,'run',side_effect=AssertionError('must not launch')):
            value=r.run(TRIAL,None,self.root/'strict',adapter_path=ADAPTER,simulator_sha256=V206_SHA)
        self.assertFalse(value['engineInvoked'])
        self.assertEqual(value['runtimeSelection'],{
            'selection':'explicit-adapter','adapterPath':str(ADAPTER.resolve()),'expectedSimulatorSha256':V206_SHA})

if __name__=='__main__':unittest.main()
