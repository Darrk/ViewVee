import importlib.util
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('viewvee_deploy', Path(__file__).with_name('deploy.py'))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)

VALID = '''web|ubuntu@host1|22|viewvee-web|8080/healthz|app|-
signaling|ubuntu@host2|22|viewvee-signal|8080/healthz|backend|proxy-1
turn|ubuntu@host3|22|viewvee-turn|running|coturn|-
'''


class DeploymentTests(unittest.TestCase):
    def test_valid_targets_and_invalid_input(self):
        self.assertEqual(len(deploy.targets(VALID)), 3)
        for invalid in ('', VALID.replace('ubuntu@host1', 'ubuntu@host1;id'),
                        VALID.replace('running|coturn', '8080/healthz|coturn'),
                        VALID + VALID.splitlines()[0] + '\n'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                deploy.targets(invalid)

    def test_preflight_all_before_deploying_any(self):
        env = {'VIEWVEE_DEPLOY_TARGETS': VALID, 'DEPLOY_REVISION': 'a' * 40}
        with mock.patch.dict(deploy.os.environ, env), mock.patch.object(deploy.sys, 'argv', ['deploy.py']), mock.patch.object(deploy, 'remote') as remote:
            deploy.main()
        self.assertEqual([call.args[2] for call in remote.call_args_list], ['check'] * 3 + ['deploy'] * 3)
        self.assertEqual([call.args[1].split('/')[-1].split(':')[0] for call in remote.call_args_list[:3]], ['viewvee-web', 'viewvee-signal', 'viewvee-turn'])


if __name__ == '__main__':
    unittest.main()
