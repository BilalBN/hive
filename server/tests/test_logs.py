import logging

from hive.logs import setup_logging


def test_web_requests_stay_out_of_the_console(tmp_path):
    """httpx logs every lookup request with album names in the URL."""
    setup_logging("INFO", tmp_path)
    try:
        assert not logging.getLogger("httpx").isEnabledFor(logging.INFO)
        assert not logging.getLogger("httpcore").isEnabledFor(logging.INFO)
        assert logging.getLogger("httpx").isEnabledFor(logging.WARNING)
        assert logging.getLogger("hive.lookup").isEnabledFor(logging.INFO)
    finally:
        root = logging.getLogger()
        for h in list(root.handlers):
            root.removeHandler(h)
            h.close()
