import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('monitor', pathlib.Path(__file__).resolve().parents[1] / 'Resources/monitor.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

class AttentionTests(unittest.TestCase):
    def setUp(self):
        self.record = dict(id='test', source='codex-app', status='working', updated=0, project='test')

    def apply(self, kind, **payload):
        monitor.apply(self.record, dict(type='response_item', payload=dict(type=kind, **payload)))

    def test_async_question_does_not_block_agent(self):
        self.apply('function_call', name='functions.request_user_input_async', call_id='async')
        self.assertEqual(self.record['status'], 'working')

    def test_answer_resumes_matching_blocking_question(self):
        self.apply('function_call', name='functions.request_user_input', call_id='question')
        self.assertEqual(self.record['status'], 'waiting')
        self.apply('function_call_output', call_id='other')
        self.assertEqual(self.record['status'], 'waiting')
        self.apply('function_call_output', call_id='question')
        self.assertEqual(self.record['status'], 'working')
        self.assertIsNone(self.record['attention'])

    def test_user_reply_clears_waiting(self):
        self.apply('function_call', name='functions.request_user_input', call_id='question')
        monitor.apply(self.record, dict(type='event_msg', payload=dict(type='user_message')))
        self.assertEqual(self.record['status'], 'working')

if __name__ == '__main__':
    unittest.main()
