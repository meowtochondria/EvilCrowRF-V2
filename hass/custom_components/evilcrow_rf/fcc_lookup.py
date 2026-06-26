"""FCC ID frequency lookup service for EvilCrowRF V2.

Scrapes fccid.io (or a configurable endpoint) to extract operating frequencies
for a given FCC ID. Uses aiohttp for async HTTP and BeautifulSoup+lxml for HTML parsing.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

import aiohttp
from bs4 import BeautifulSoup

from .const import DEFAULT_FCC_API_ENDPOINT

_LOGGER = logging.getLogger(__name__)

# Regex to match frequency values in the scraped table.
# Matches patterns like "315.00 MHz", "433.92 MHz", "2.4 GHz", "868.3 MHz"
_FREQ_RE = re.compile(
    r"(\d+(?:\.\d+)?)\s*(MHz|kHz|GHz)",
    re.IGNORECASE,
)

# CSS selector for the FCC ID detail table rows.
# fccid.io uses a table with class "table" inside the main content area.
_TABLE_ROW_SELECTOR = "table.table tbody tr"

# Frequency range thresholds for sanity checking (30 kHz – 300 GHz).
_MIN_FREQ_HZ = 30_000
_MAX_FREQ_HZ = 300_000_000_000


class FccLookupError(Exception):
    """Raised when the FCC ID lookup fails (network, parse, or unexpected format)."""


@dataclass
class FccLookupResult:
    """Parsed result from an FCC ID lookup."""

    fcc_id: str
    frequencies_hz: list[int] = field(default_factory=list)
    raw_data: dict[str, str] = field(default_factory=dict)
    url: str = ""


class FccLookupService:
    """Service for looking up FCC IDs and extracting operating frequencies.

    Uses an aiohttp session to fetch the FCC ID page and parses the table
    rows to extract frequency information. The endpoint URL is configurable
    via the integration YAML config.

    Attributes:
        _session: aiohttp ClientSession (can be shared or owned).
        _endpoint_template: URL template with {fcc_id} placeholder.
        _timeout: aiohttp.ClientTimeout for requests.
        _own_session: True if this service created the session.
    """

    def __init__(
        self,
        session: aiohttp.ClientSession | None = None,
        endpoint_template: str | None = None,
        request_timeout: int = 15,
    ) -> None:
        """Initialize the FCC lookup service.

        Args:
            session: An optional shared aiohttp ClientSession. If None, a new
                session is created and managed internally.
            endpoint_template: URL template with {fcc_id} placeholder. Falls
                back to DEFAULT_FCC_API_ENDPOINT.
            request_timeout: Timeout in seconds for HTTP requests.
        """
        self._session = session
        self._endpoint_template = endpoint_template or DEFAULT_FCC_API_ENDPOINT
        self._timeout = aiohttp.ClientTimeout(total=request_timeout)
        self._own_session = session is None
        self._freq_re = _FREQ_RE  # allow override in tests

    async def lookup(self, fcc_id: str) -> FccLookupResult:
        """Look up an FCC ID and return parsed frequency data.

        Args:
            fcc_id: The FCC ID string (e.g. "A4V-RM102").

        Returns:
            FccLookupResult with extracted frequencies in Hz.

        Raises:
            FccLookupError: On network failure, parse failure, or invalid FCC ID.
        """
        cleaned = fcc_id.strip().upper()
        if not cleaned:
            raise FccLookupError("FCC ID must not be empty")

        url = self._endpoint_template.format(fcc_id=cleaned)
        _LOGGER.debug("Fetching FCC ID data from %s", url)

        try:
            html = await self._fetch_page(url)
        except (aiohttp.ClientError, TimeoutError, OSError) as exc:
            raise FccLookupError(f"Failed to fetch FCC ID '{cleaned}': {exc}") from exc

        if not html:
            raise FccLookupError(f"Empty response for FCC ID '{cleaned}' from {url}")

        try:
            frequencies_hz, raw_data = self._parse_page(html)
        except Exception as exc:
            raise FccLookupError(f"Failed to parse FCC ID page for '{cleaned}': {exc}") from exc

        return FccLookupResult(
            fcc_id=cleaned,
            frequencies_hz=frequencies_hz,
            raw_data=raw_data,
            url=url,
        )

    async def _fetch_page(self, url: str) -> str:
        """Fetch the FCC ID page HTML.

        Creates a session if this service owns one.
        """
        if self._session is None or self._session.closed:
            if self._own_session:
                self._session = aiohttp.ClientSession()
            else:
                raise FccLookupError("Shared session is closed")

        async with self._session.get(
            url,
            timeout=self._timeout,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "en-US,en;q=0.5",
            },
            raise_for_status=False,
        ) as resp:
            if resp.status != 200:
                raise FccLookupError(f"HTTP {resp.status} from {url}")
            return await resp.text()

    def _parse_page(self, html: str) -> tuple[list[int], dict[str, str]]:
        """Parse FCC ID page HTML and extract frequency data.

        Args:
            html: Raw HTML content of the FCC ID page.

        Returns:
            Tuple of (frequencies_hz, raw_data_dict).

        The method looks for:
          1. A table with class "table" containing frequency information.
          2. Any text containing "Frequency" or "MHz"/"kHz"/"GHz" patterns.
          3. Falls back to regex search on the full text.
        """
        soup = BeautifulSoup(html, "lxml")

        frequencies_hz_set: set[int] = set()
        raw_data: dict[str, str] = {}

        # Strategy 1: Parse specific table rows
        rows = soup.select(_TABLE_ROW_SELECTOR)
        for row in rows:
            cells = row.find_all("td")
            if len(cells) < 2:
                continue
            header_text = cells[0].get_text(strip=True).lower()
            value_text = cells[1].get_text(strip=True)

            # Store raw key-value pairs
            raw_data[cells[0].get_text(strip=True)] = value_text

            # Check if this row mentions frequency
            if "frequency" in header_text or "freq" in header_text:
                matched_freqs = self._extract_frequencies(value_text)
                frequencies_hz_set.update(matched_freqs)

        # Strategy 2: Scan all visible text on the page for frequency patterns
        if not frequencies_hz_set:
            page_text = soup.get_text(separator=" ", strip=True)
            matched_freqs = self._extract_frequencies(page_text)
            frequencies_hz_set.update(matched_freqs)

        # Strategy 3: Scan <pre>, <code>, and <div> blocks for raw data
        if not frequencies_hz_set:
            for tag in soup.find_all(["pre", "code", "div"]):
                text = tag.get_text(separator=" ", strip=True)
                matched_freqs = self._extract_frequencies(text)
                frequencies_hz_set.update(matched_freqs)

        # Convert to sorted list after filtering
        frequencies_hz = sorted(f for f in frequencies_hz_set if f is not None)

        return frequencies_hz, raw_data

    def _extract_frequencies(self, text: str) -> list[int]:
        """Extract frequency values from text and convert to Hz.

        Args:
            text: String that may contain frequency patterns.

        Returns:
            List of frequencies in Hz, filtered for sanity.
        """
        frequencies: list[int] = []
        for match in self._freq_re.finditer(text):
            value = float(match.group(1))
            unit = match.group(2).upper()

            if unit == "GHZ":
                freq_hz = int(value * 1_000_000_000)
            elif unit == "KHZ":
                freq_hz = int(value * 1_000)
            else:  # MHz
                freq_hz = int(value * 1_000_000)

            # Sanity check: filter out-of-range values
            if _MIN_FREQ_HZ <= freq_hz <= _MAX_FREQ_HZ:
                frequencies.append(freq_hz)

        return frequencies

    async def async_close(self) -> None:
        """Close the owned aiohttp session if this service created it."""
        if self._own_session and self._session is not None:
            if not self._session.closed:
                await self._session.close()
            self._session = None
            self._own_session = False

    async def __aenter__(self) -> FccLookupService:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: object | None,
    ) -> None:
        await self.async_close()


def normalize_fcc_id(raw: str) -> str:
    """Normalize an FCC ID string: strip whitespace, upper-case.

    Args:
        raw: Raw FCC ID input.

    Returns:
        Normalized FCC ID.
    """
    return raw.strip().upper()
