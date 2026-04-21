// markdown-render.js — renders markdown and manages comment threads
// Security: all user content is sanitized via DOMPurify before DOM insertion.
// All innerHTML assignments are preceded by DOMPurify.sanitize() to prevent XSS.

var contentEl = document.getElementById('content');
var tocEl = document.getElementById('toc');

// State
var commentThreads = [];
var draftComments = [];
var expandedThreads = {};
var tocVisible = true;

// ── Configuration ───────────────────────────────────────────────
// Injected from Swift via setParleyConfig() to maintain a single source of truth.
// Defaults mirror the Swift-side values; injection overwrites them at load time.
var _parleyConfig = {
    maxBodyLength: 100000,      // PRViewModel.maxBodyLength
    maxRetryAttempts: 3,        // postToSwift error-report retry cap
    maxReportFailures: 50,      // reportToSwift failure cap before giving up
    cssEscapeMaxLength: 100000  // DoS guard for cssEscape fallback
};

// Called by Swift coordinator after template loads to inject config values.
// Keeps JS constants synchronized without manual duplication.
function setParleyConfig(config) {
    if (!config || typeof config !== 'object') return;
    for (var key in _parleyConfig) {
        if (config.hasOwnProperty(key) && typeof config[key] === 'number') {
            _parleyConfig[key] = config[key];
        }
    }
    MAX_BODY_LENGTH = _parleyConfig.maxBodyLength;
}

// ── Error tracking (encapsulated) ──────────────────────────────
// Avoids polluting the global scope; counters are capped to prevent
// unbounded accumulation in long sessions.
var _errorState = {
    postRetries: 0,
    reportFailures: 0,
    // Serializes postToSwift error handling so one success can't
    // race-reset the counter while another call is mid-retry.
    posting: false
};

// Post message to Swift. Errors are bridged back via a dedicated logError action
// so they surface in os.Logger instead of vanishing into the WebKit console void.
//
// Failure handling: if the error report itself fails, we log to console and stop.
// A counter caps error-reporting attempts to prevent infinite retry loops (e.g. if
// the message handler is permanently broken). Retries use exponential backoff
// via setTimeout to avoid overwhelming the message bridge during transient issues.
function postToSwift(msg) {
    _errorState.posting = true;
    try {
        window.webkit.messageHandlers.parley.postMessage(msg);
        _errorState.postRetries = 0;
    } catch (err) {
        // Sanitize: only include known action names; truncate error to prevent
        // sensitive WebKit context data from leaking into logs.
        var KNOWN_ACTIONS = ['addComment', 'submitReply', 'editComment', 'removeComment',
                             'expandThread', 'collapseThread', 'logError'];
        var rawAction = (msg && typeof msg === 'object') ? String(msg.action || '') : '';
        var actionName = KNOWN_ACTIONS.indexOf(rawAction) !== -1 ? rawAction : '<redacted>';
        var rawError = String(err);
        var safeError = rawError.length > 200 ? rawError.slice(0, 200) + '...' : rawError;
        var errorMsg = 'postToSwift failed for action "' + actionName + '": ' + safeError;
        console.error(errorMsg);
        // Bridge to Swift logger with exponential backoff
        if (_errorState.postRetries < _parleyConfig.maxRetryAttempts) {
            var attempt = _errorState.postRetries;
            _errorState.postRetries++;
            var delay = 100 * Math.pow(2, attempt); // 100ms, 200ms, 400ms
            setTimeout(function() {
                try {
                    window.webkit.messageHandlers.parley.postMessage({
                        action: 'logError', source: 'postToSwift', detail: errorMsg
                    });
                } catch (reportErr) {
                    console.error('postToSwift: error reporting also failed (' +
                        _errorState.postRetries + '/' + _parleyConfig.maxRetryAttempts + '): ' +
                        String(reportErr).slice(0, 200));
                }
            }, delay);
        }
    } finally {
        _errorState.posting = false;
    }
}

// Report a warning/error from JS to Swift for proper logging.
// Failed reports fall back to console.warn (not silently swallowed).
// Capped at maxReportFailures to prevent unbounded accumulation in long sessions.
function reportToSwift(source, detail) {
    if (_errorState.reportFailures >= _parleyConfig.maxReportFailures) {
        return; // silently drop — we've already logged plenty of failures
    }
    try {
        window.webkit.messageHandlers.parley.postMessage({
            action: 'logError', source: source, detail: String(detail)
        });
        _errorState.reportFailures = 0;
    } catch (err) {
        _errorState.reportFailures++;
        console.warn('[' + source + '] ' + detail + ' (report failed #' + _errorState.reportFailures + ': ' + err + ')');
    }
}

// Sanitize HTML to prevent XSS
function sanitize(html) {
    return DOMPurify.sanitize(html, { ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'a', 'code', 'pre', 'p', 'br', 'ul', 'ol', 'li', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'img', 'hr', 'del', 'input', 'span', 'div', 'dl', 'dt', 'dd', 'sup', 'sub'], ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'class', 'type', 'checked', 'disabled', 'width', 'height'] });
}

// Render markdown with line-level anchoring
function renderMarkdown(markdown, threads, drafts) {
    commentThreads = threads || [];
    draftComments = drafts || [];
    updateDraftIndex();

    // Strip and render frontmatter
    var content = markdown;
    var frontmatter = '';
    var fmMatch = content.match(/^---\n([\s\S]*?)\n---\n/);
    if (fmMatch) {
        frontmatter = fmMatch[1];
        content = content.slice(fmMatch[0].length);
    }

    // Configure marked
    marked.setOptions({
        gfm: true,
        breaks: false,
        highlight: function(code, lang) {
            if (lang && hljs.getLanguage(lang)) {
                return hljs.highlight(code, { language: lang }).value;
            }
            return hljs.highlightAuto(code).value;
        }
    });

    var rawHtml = marked.parse(content);
    var safeHtml = sanitize(rawHtml);

    var rendered = '';
    if (frontmatter) {
        var fmDiv = document.createElement('div');
        fmDiv.className = 'frontmatter';
        fmDiv.textContent = frontmatter;
        rendered += fmDiv.outerHTML;
    }

    // Wrap block elements with line-block divs for comment anchoring
    rendered += wrapWithLineBlocks(safeHtml, content, fmMatch ? fmMatch[0].split('\n').length : 1);

    // SECURITY: sanitize() wraps DOMPurify.sanitize with strict config
    contentEl.innerHTML = sanitize(rendered);
    injectAddCommentButtons();
    injectCommentUI();
    buildTOC();
}

// Wrap block-level HTML elements with line-block divs
function wrapWithLineBlocks(html, sourceContent, startLine) {
    var temp = document.createElement('div');
    // SECURITY: sanitize() wraps DOMPurify.sanitize with strict config
    temp.innerHTML = sanitize(html);

    var lineCounter = startLine;
    var children = Array.from(temp.children);

    children.forEach(function(child) {
        var line = lineCounter;
        child.classList.add('line-block');
        child.setAttribute('data-source-line', line);

        // Estimate lines consumed by this block
        var text = child.textContent || '';
        var blockLines = Math.max(1, (text.match(/\n/g) || []).length + 1);
        lineCounter += blockLines;
    });

    return temp.innerHTML;
}

// Add "+" buttons to every line-block in the live DOM (after sanitization)
function injectAddCommentButtons() {
    var blocks = contentEl.querySelectorAll('.line-block');
    blocks.forEach(function(block) {
        var line = parseInt(block.getAttribute('data-source-line'));
        if (isNaN(line)) return;

        var btn = document.createElement('button');
        btn.className = 'add-comment-btn';
        btn.textContent = '+';
        btn.addEventListener('click', function(e) {
            e.stopPropagation();
            showNewCommentBox(line);
        });
        block.insertBefore(btn, block.firstChild);
    });
}

// Inject comment indicators and threads
function injectCommentUI() {
    var threadsByLine = {};
    commentThreads.forEach(function(thread) {
        var line = thread.line;
        if (!threadsByLine[line]) threadsByLine[line] = [];
        threadsByLine[line].push(thread);
    });

    var draftsByLine = {};
    draftComments.forEach(function(draft) {
        if (!draftsByLine[draft.line]) draftsByLine[draft.line] = [];
        draftsByLine[draft.line].push(draft);
    });

    var allLines = new Set(
        Object.keys(threadsByLine).map(Number).concat(Object.keys(draftsByLine).map(Number))
    );

    allLines.forEach(function(line) {
        var block = document.querySelector('[data-source-line="' + line + '"]');
        if (!block) return;

        var threads = threadsByLine[line] || [];
        var drafts = draftsByLine[line] || [];

        if (threads.length > 0) {
            var totalComments = threads.reduce(function(sum, t) { return sum + t.comments.length; }, 0);

            var indicator = document.createElement('div');
            indicator.className = 'comment-indicator';
            var countSpan = document.createElement('span');
            countSpan.className = 'count';
            countSpan.textContent = totalComments + ' comment' + (totalComments > 1 ? 's' : '');
            indicator.appendChild(countSpan);
            indicator.addEventListener('click', function() { toggleThread(line); });
            block.appendChild(indicator);

            var threadContainer = document.createElement('div');
            threadContainer.className = 'comment-thread' + (expandedThreads[line] ? ' expanded' : '');
            threadContainer.id = 'thread-' + line;

            threads.forEach(function(thread) {
                thread.comments.forEach(function(comment) {
                    var commentEl = document.createElement('div');
                    commentEl.className = 'comment';

                    var authorSpan = document.createElement('span');
                    authorSpan.className = 'comment-author';
                    authorSpan.textContent = '@' + comment.author;
                    commentEl.appendChild(authorSpan);

                    var dateSpan = document.createElement('span');
                    dateSpan.className = 'comment-date';
                    dateSpan.textContent = formatDate(comment.createdAt);
                    commentEl.appendChild(dateSpan);

                    var bodyDiv = document.createElement('div');
                    bodyDiv.className = 'comment-body';
                    // SECURITY: sanitize() wraps DOMPurify.sanitize with strict config
                    bodyDiv.innerHTML = sanitize(marked.parse(comment.body));
                    commentEl.appendChild(bodyDiv);

                    threadContainer.appendChild(commentEl);
                });

                var replyWrap = document.createElement('div');
                replyWrap.className = 'reply-wrap';

                var replyTextareaId = 'reply-' + thread.id;
                replyWrap.appendChild(createFormattingToolbar(replyTextareaId));

                var replyBox = document.createElement('div');
                replyBox.className = 'reply-box';

                var textarea = document.createElement('textarea');
                textarea.placeholder = 'Reply...';
                textarea.id = replyTextareaId;
                replyBox.appendChild(textarea);

                var replyBtn = document.createElement('button');
                replyBtn.textContent = 'Reply';
                var threadId = thread.id;
                var threadLine = line;
                replyBtn.addEventListener('click', function() { submitReply(threadId, threadLine); });
                replyBox.appendChild(replyBtn);

                replyWrap.appendChild(replyBox);
                threadContainer.appendChild(replyWrap);
            });

            block.appendChild(threadContainer);
        }

        drafts.forEach(function(draft) {
            var draftEl = document.createElement('div');
            draftEl.className = 'draft-indicator';
            draftEl.setAttribute('data-draft-id', draft.id);

            var badge = document.createElement('span');
            badge.className = 'badge';
            badge.textContent = 'DRAFT';
            draftEl.appendChild(badge);

            var bodySpan = document.createElement('span');
            bodySpan.className = 'draft-body-text';
            bodySpan.textContent = draft.body;
            draftEl.appendChild(bodySpan);

            var editBtn = document.createElement('button');
            editBtn.className = 'draft-edit-btn';
            editBtn.textContent = 'Edit';
            editBtn.addEventListener('click', function(e) {
                e.stopPropagation();
                editDraftComment(draft.id);
            });
            draftEl.appendChild(editBtn);

            block.appendChild(draftEl);
        });
    });
}

function toggleThread(line) {
    expandedThreads[line] = !expandedThreads[line];
    var thread = document.getElementById('thread-' + line);
    if (thread) {
        thread.classList.toggle('expanded');
    }
    postToSwift({ action: expandedThreads[line] ? 'expandThread' : 'collapseThread', line: line });
}

function showNewCommentBox(line) {
    document.querySelectorAll('.new-comment-box').forEach(function(el) { el.remove(); });

    var block = document.querySelector('[data-source-line="' + line + '"]');
    if (!block) return;

    var box = document.createElement('div');
    box.className = 'new-comment-box';

    var textareaId = 'new-comment-' + line;
    box.appendChild(createFormattingToolbar(textareaId));

    var replyBox = document.createElement('div');
    replyBox.className = 'reply-box';

    var textarea = document.createElement('textarea');
    textarea.placeholder = 'Add a comment on line ' + line + '...';
    textarea.id = textareaId;
    replyBox.appendChild(textarea);

    var stageBtn = document.createElement('button');
    stageBtn.className = 'stage-btn';
    stageBtn.textContent = 'Stage';
    stageBtn.addEventListener('click', function() { stageComment(line); });
    replyBox.appendChild(stageBtn);

    box.appendChild(replyBox);
    block.appendChild(box);

    setTimeout(function() { textarea.focus(); }, 50);
}

function stageComment(line) {
    var textarea = document.getElementById('new-comment-' + line);
    if (!textarea || !textarea.value.trim()) return;
    postToSwift({ action: 'addComment', line: line, body: textarea.value.trim() });
}

function submitReply(threadId, line) {
    var textarea = document.getElementById('reply-' + threadId);
    if (!textarea || !textarea.value.trim()) return;
    postToSwift({ action: 'submitReply', commentId: threadId, line: line, body: textarea.value.trim() });
    textarea.value = '';
}

function scrollToLine(line) {
    var block = document.querySelector('[data-source-line="' + line + '"]');
    if (!block) return;
    block.scrollIntoView({ behavior: 'smooth', block: 'center' });
    block.classList.add('highlighted');
    setTimeout(function() { block.classList.remove('highlighted'); }, 2000);
}

function expandThread(line) {
    expandedThreads[line] = true;
    var thread = document.getElementById('thread-' + line);
    if (thread) thread.classList.add('expanded');
    scrollToLine(line);
}

function formatDate(dateStr) {
    try {
        var d = new Date(dateStr);
        return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    } catch(e) {
        return dateStr;
    }
}

// Table of contents
//
//   ┌──────────┐ ┌────────────────────────────────────┐
//   │ TOC      │ │ rendered markdown content           │
//   │ ├ Intro  │ │                                     │
//   │ ├ Goals  │ │ ...                                 │
//   │ └ API    │ │                                     │
//   └──────────┘ └────────────────────────────────────┘
//
// Sticky on the left, generated from h1-h6 in the content.

function buildTOC() {
    if (!tocEl) return;

    var headings = contentEl.querySelectorAll('h1, h2, h3, h4, h5, h6');
    if (headings.length === 0) {
        tocEl.style.display = 'none';
        return;
    }

    // Clear previous TOC
    while (tocEl.firstChild) tocEl.removeChild(tocEl.firstChild);

    var title = document.createElement('div');
    title.className = 'toc-title';
    title.textContent = 'Contents';
    tocEl.appendChild(title);

    var list = document.createElement('ul');
    list.className = 'toc-list';

    headings.forEach(function(heading, idx) {
        // Give each heading an id for anchoring
        var id = 'heading-' + idx;
        heading.id = id;

        var level = parseInt(heading.tagName.charAt(1));
        var item = document.createElement('li');
        item.className = 'toc-item toc-level-' + level;

        var link = document.createElement('a');
        link.textContent = heading.textContent.replace(/^\+\s*/, ''); // strip "+" button text
        link.href = '#' + id;
        link.addEventListener('click', function(e) {
            e.preventDefault();
            heading.scrollIntoView({ behavior: 'smooth', block: 'start' });
            // highlight briefly
            heading.classList.add('highlighted');
            setTimeout(function() { heading.classList.remove('highlighted'); }, 2000);
        });

        item.appendChild(link);
        list.appendChild(item);
    });

    tocEl.appendChild(list);
    tocEl.style.display = tocVisible ? 'block' : 'none';
}

function toggleTOC() {
    tocVisible = !tocVisible;
    if (tocEl) {
        tocEl.style.display = tocVisible ? 'block' : 'none';
    }
}

// ── Markdown formatting toolbar ─────────────────────────────────
//
//  B  I  <>  ~  ""  -  1.  [ ]  H
//
// Inserted above every comment/reply textarea. Wraps selected text
// in the textarea with the appropriate markdown syntax.

function createFormattingToolbar(textareaId) {
    var toolbar = document.createElement('div');
    toolbar.className = 'fmt-toolbar';

    var buttons = [
        { label: 'B', title: 'Bold', prefix: '**', suffix: '**', placeholder: 'bold text' },
        { label: 'I', title: 'Italic', prefix: '_', suffix: '_', placeholder: 'italic text' },
        { label: '<>', title: 'Inline code', prefix: '`', suffix: '`', placeholder: 'code' },
        { label: '~', title: 'Strikethrough', prefix: '~~', suffix: '~~', placeholder: 'text' },
        { label: '""', title: 'Quote', prefix: '\n> ', suffix: '', placeholder: 'quote', line: true },
        { label: '-', title: 'Bulleted list', prefix: '\n- ', suffix: '', placeholder: 'item', line: true },
        { label: '1.', title: 'Numbered list', prefix: '\n1. ', suffix: '', placeholder: 'item', line: true },
        { label: '[ ]', title: 'Task list', prefix: '\n- [ ] ', suffix: '', placeholder: 'task', line: true },
        { label: 'H', title: 'Heading', prefix: '\n### ', suffix: '', placeholder: 'heading', line: true },
        { label: 'a', title: 'Link', prefix: '[', suffix: '](url)', placeholder: 'link text' },
    ];

    buttons.forEach(function(b) {
        var btn = document.createElement('button');
        btn.className = 'fmt-btn';
        btn.textContent = b.label;
        btn.title = b.title;
        btn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            applyFormat(textareaId, b.prefix, b.suffix, b.placeholder, b.line);
        });
        toolbar.appendChild(btn);
    });

    return toolbar;
}

function applyFormat(textareaId, prefix, suffix, placeholder, isLine) {
    var ta = document.getElementById(textareaId);
    if (!ta) return;

    var start = ta.selectionStart;
    var end = ta.selectionEnd;
    var text = ta.value;
    var selected = text.slice(start, end);
    var insert = selected || placeholder;

    // For line-level formats, strip the leading newline if we're at the start
    var actualPrefix = prefix;
    if (isLine && (start === 0 || text[start - 1] === '\n')) {
        actualPrefix = prefix.replace(/^\n/, '');
    }

    ta.value = text.slice(0, start) + actualPrefix + insert + suffix + text.slice(end);

    // Place cursor after inserted text (or select the placeholder)
    var cursorStart = start + actualPrefix.length;
    var cursorEnd = cursorStart + insert.length;
    ta.selectionStart = cursorStart;
    ta.selectionEnd = cursorEnd;
    ta.focus();
}

// ── Selection-based comments ────────────────────────────────────
//
// Select text → floating "Comment" button appears → click to open
// a comment box with the selected text pre-quoted.

var selectionPopover = null;

document.addEventListener('mouseup', function(e) {
    // Small delay so the selection is finalized
    setTimeout(handleSelectionChange, 10);
});

document.addEventListener('mousedown', function(e) {
    // Dismiss popover if clicking outside it
    if (selectionPopover && !selectionPopover.contains(e.target)) {
        removeSelectionPopover();
    }
});

function handleSelectionChange() {
    var sel = window.getSelection();
    var text = sel.toString().trim();

    if (!text || text.length < 2) {
        removeSelectionPopover();
        return;
    }

    // Find which line-blocks the selection spans
    var anchorNode = sel.anchorNode;
    var focusNode = sel.focusNode;
    var startBlock = findParentLineBlock(anchorNode);
    var endBlock = findParentLineBlock(focusNode);
    if (!startBlock) {
        removeSelectionPopover();
        return;
    }

    var startLine = parseInt(startBlock.getAttribute('data-source-line'));
    var endLine = endBlock ? parseInt(endBlock.getAttribute('data-source-line')) : startLine;
    if (isNaN(startLine)) {
        removeSelectionPopover();
        return;
    }
    // Ensure startLine <= endLine (selection direction can go either way)
    if (endLine < startLine) {
        var tmp = startLine; startLine = endLine; endLine = tmp;
    }

    // Don't show popover if selection is inside a comment thread or reply box
    if (findParentWithClass(anchorNode, 'comment-thread') ||
        findParentWithClass(anchorNode, 'reply-box') ||
        findParentWithClass(anchorNode, 'new-comment-box') ||
        findParentWithClass(anchorNode, 'draft-indicator') ||
        findParentWithClass(anchorNode, 'draft-edit-box')) {
        return;
    }

    // Collect full text of all line-blocks in the range for the quote
    var fullLineText = getLineBlockText(startLine, endLine);

    showSelectionPopover(sel, startLine, endLine, fullLineText);
}

function showSelectionPopover(sel, startLine, endLine, selectedText) {
    removeSelectionPopover();

    var range = sel.getRangeAt(0);
    var rect = range.getBoundingClientRect();

    selectionPopover = document.createElement('div');
    selectionPopover.className = 'selection-popover';
    selectionPopover.style.top = (rect.bottom + window.scrollY + 6) + 'px';
    selectionPopover.style.left = (rect.left + window.scrollX + rect.width / 2) + 'px';

    var btn = document.createElement('button');
    btn.className = 'selection-comment-btn';
    var label = startLine === endLine ? 'Comment on line ' + startLine : 'Comment on lines ' + startLine + '-' + endLine;
    btn.textContent = label;
    btn.addEventListener('click', function(e) {
        e.preventDefault();
        e.stopPropagation();
        showSelectionCommentBox(startLine, endLine, selectedText);
        removeSelectionPopover();
        window.getSelection().removeAllRanges();
    });

    selectionPopover.appendChild(btn);
    document.body.appendChild(selectionPopover);
}

function removeSelectionPopover() {
    if (selectionPopover) {
        selectionPopover.remove();
        selectionPopover = null;
    }
}

function showSelectionCommentBox(startLine, endLine, selectedText) {
    document.querySelectorAll('.new-comment-box').forEach(function(el) { el.remove(); });

    // Anchor the comment box to the end-line block (where GH anchors the comment)
    var block = document.querySelector('[data-source-line="' + endLine + '"]');
    if (!block) block = document.querySelector('[data-source-line="' + startLine + '"]');
    if (!block) return;

    var box = document.createElement('div');
    box.className = 'new-comment-box';

    // Line range label
    var lineLabel = document.createElement('div');
    lineLabel.className = 'selection-line-label';
    lineLabel.textContent = startLine === endLine ? 'Line ' + endLine : 'Lines ' + startLine + '-' + endLine;
    box.appendChild(lineLabel);

    // Show quoted selection
    var quoteEl = document.createElement('div');
    quoteEl.className = 'selection-quote';
    quoteEl.textContent = selectedText;
    box.appendChild(quoteEl);

    var textareaId = 'new-comment-' + endLine;
    box.appendChild(createFormattingToolbar(textareaId));

    var replyBox = document.createElement('div');
    replyBox.className = 'reply-box';

    var textarea = document.createElement('textarea');
    textarea.placeholder = 'Add your comment...';
    textarea.id = textareaId;
    replyBox.appendChild(textarea);

    var stageBtn = document.createElement('button');
    stageBtn.className = 'stage-btn';
    stageBtn.textContent = 'Stage';
    var quotedText = selectedText;
    var sl = startLine;
    var el = endLine;
    stageBtn.addEventListener('click', function() {
        stageSelectionComment(sl, el, quotedText);
    });
    replyBox.appendChild(stageBtn);

    box.appendChild(replyBox);
    block.appendChild(box);

    setTimeout(function() { textarea.focus(); }, 50);
}

function stageSelectionComment(startLine, endLine, selectedText) {
    var textarea = document.getElementById('new-comment-' + endLine);
    if (!textarea) return;
    var comment = textarea.value.trim();
    if (!comment && !selectedText) return;

    var body = '';
    if (selectedText) {
        body += '> ' + selectedText.split('\n').join('\n> ') + '\n\n';
    }
    if (comment) {
        body += comment;
    }

    // Send startLine for multi-line GH API support
    var msg = { action: 'addComment', line: endLine, body: body.trim() };
    if (startLine !== endLine) {
        msg.startLine = startLine;
    }
    postToSwift(msg);
}

// Get the full text content of all line-blocks in a range
function getLineBlockText(startLine, endLine) {
    var blocks = contentEl.querySelectorAll('.line-block');
    var parts = [];
    blocks.forEach(function(block) {
        var line = parseInt(block.getAttribute('data-source-line'));
        if (isNaN(line) || line < startLine || line > endLine) return;
        // Get text without the "+" button text
        var clone = block.cloneNode(true);
        clone.querySelectorAll('.add-comment-btn, .comment-indicator, .comment-thread, .draft-indicator, .draft-edit-box, .new-comment-box').forEach(function(el) { el.remove(); });
        var text = clone.textContent.trim();
        if (text) parts.push(text);
    });
    return parts.join('\n');
}

// ── Draft comment editing ───────────────────────────────────
//
//  DRAFT  "body text"  [Edit]    <- indicator (default)
//  ┌──────────────────────────┐
//  │ formatting toolbar       │  <- edit box (active)
//  │ textarea                 │
//  │ [Save]  [Cancel]         │
//  └──────────────────────────┘

// O(1) draft lookup by ID (rebuilt when drafts change)
var draftCommentsById = {};
var lastDraftFingerprint = '';

function updateDraftIndex() {
    // Pipe separator: can't appear in UUIDs, avoids null-byte collision risk
    var fingerprint = draftComments.map(function(d) { return d.id; }).join('|');
    if (fingerprint === lastDraftFingerprint) return;
    lastDraftFingerprint = fingerprint;
    draftCommentsById = {};
    for (var i = 0; i < draftComments.length; i++) {
        draftCommentsById[draftComments[i].id] = draftComments[i];
    }
}

var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Initialized from _parleyConfig; updated by setParleyConfig() injection.
var MAX_BODY_LENGTH = _parleyConfig.maxBodyLength;

function isValidUUID(str) {
    return typeof str === 'string' && UUID_RE.test(str);
}

// Escape a string for safe use inside CSS attribute selectors.
// Uses native CSS.escape() when available (WebKit supports it), with a
// comprehensive fallback per the CSS.escape() spec (CSSWG).
//
// Character handling per https://drafts.csswg.org/cssom/#serialize-an-identifier:
//   U+0000           -> U+FFFD (replacement character)
//   U+0001..U+001F   -> hex escape + space  (C0 control chars)
//   U+007F           -> hex escape + space  (DEL)
//   Leading digit     -> hex escape + space  (0-9 at position 0)
//   Lone hyphen       -> backslash escape    (single "-")
//   Hyphen+digit      -> hex escape + space  (digit at position 1 after "-")
//   A-Z, a-z, 0-9,
//   hyphen, underscore,
//   U+0080+           -> pass through        (safe ident chars)
//   Everything else   -> backslash escape    (punctuation, symbols, etc.)
function cssEscape(str) {
    if (typeof str !== 'string') {
        str = String(str);
    }
    if (str.length > _parleyConfig.cssEscapeMaxLength) {
        reportToSwift('cssEscape', 'input too long (' + str.length + '), truncating');
        str = str.slice(0, _parleyConfig.cssEscapeMaxLength);
    }
    if (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') {
        return CSS.escape(str);
    }
    var result = '';
    for (var i = 0; i < str.length; i++) {
        var ch = str.charCodeAt(i);
        if (ch === 0x0000) {
            result += '\uFFFD';
            continue;
        }
        if ((ch >= 0x0001 && ch <= 0x001F) || ch === 0x007F) {
            result += '\\' + ch.toString(16) + ' ';
            continue;
        }
        if (i === 0) {
            if (ch >= 0x0030 && ch <= 0x0039) {
                result += '\\' + ch.toString(16) + ' ';
                continue;
            }
            if (ch === 0x002D && str.length === 1) {
                result += '\\' + str.charAt(i);
                continue;
            }
        }
        if (i === 1 && str.charCodeAt(0) === 0x002D && ch >= 0x0030 && ch <= 0x0039) {
            result += '\\' + ch.toString(16) + ' ';
            continue;
        }
        if (ch >= 0x0080 || ch === 0x002D || ch === 0x005F ||
            (ch >= 0x0030 && ch <= 0x0039) || (ch >= 0x0041 && ch <= 0x005A) ||
            (ch >= 0x0061 && ch <= 0x007A)) {
            result += str.charAt(i);
            continue;
        }
        result += '\\' + str.charAt(i);
    }
    return result;
}

function findDraftById(draftId) {
    return draftCommentsById[draftId] || null;
}

// Sanitize body text: strip control characters using a blocklist approach.
// Allowed: tab (0x09) and newline (0x0A) — legitimate in markdown.
// Stripped ranges (mirrors Swift sanitizedBody):
//   0x00-0x08  C0 control chars before tab
//   0x0B-0x1F  C0 control chars after newline (includes CR 0x0D)
//   0x7F-0x9F  DEL + C1 control chars
// CR (0x0D) is stripped — unnecessary in markdown, potential injection vector.
// Reports to Swift only that sanitization occurred (not the count, to prevent
// an attacker from using log volume to infer filtered content).
function sanitizeBodyText(str) {
    var cleaned = str.replace(/[\x00-\x08\x0B-\x1F\x7F-\x9F]/g, '');
    if (cleaned.length !== str.length) {
        reportToSwift('sanitizeBodyText', 'stripped control characters from input');
    }
    return cleaned;
}

// Find a DOM element by class name and data-draft-id using dataset comparison.
// Avoids CSS selector construction (and cssEscape edge cases) by comparing
// the raw dataset.draftId property via strict equality.
// Validates draftId format before searching to reject malformed input early.
function findByDraftId(className, draftId) {
    if (!isValidUUID(draftId)) {
        reportToSwift('findByDraftId', 'invalid draftId format');
        return null;
    }
    var candidates = document.querySelectorAll('.' + className);
    for (var i = 0; i < candidates.length; i++) {
        if (candidates[i].dataset.draftId === draftId) return candidates[i];
    }
    return null;
}

function editDraftComment(draftId) {
    if (!isValidUUID(draftId)) {
        reportToSwift('editDraftComment', 'invalid UUID: ' + draftId);
        return;
    }

    var draft = findDraftById(draftId);
    if (!draft) {
        reportToSwift('editDraftComment', 'draft not found: ' + draftId);
        return;
    }

    // Prevent double-click from creating duplicate edit boxes
    if (findByDraftId('draft-edit-box', draftId)) return;

    var indicator = findByDraftId('draft-indicator', draftId);
    if (!indicator) return;

    indicator.classList.add('hidden');

    var editBox = createEditBox(draftId, draft.body);
    indicator.parentNode.insertBefore(editBox, indicator.nextSibling);

    var textarea = document.getElementById('draft-edit-' + draftId);
    if (textarea) setTimeout(function() { textarea.focus(); }, 50);
}

function createEditBox(draftId, body) {
    var editBox = document.createElement('div');
    editBox.className = 'draft-edit-box';
    editBox.setAttribute('data-draft-id', draftId);

    var textareaId = 'draft-edit-' + draftId;
    editBox.appendChild(createFormattingToolbar(textareaId));

    var replyBox = document.createElement('div');
    replyBox.className = 'reply-box';

    var textarea = document.createElement('textarea');
    textarea.id = textareaId;
    textarea.value = sanitizeBodyText(body);
    // Clear stale error styling when user starts typing again
    textarea.addEventListener('input', function() {
        clearSaveError(draftId);
    });
    replyBox.appendChild(textarea);

    replyBox.appendChild(createEditActions(draftId));
    editBox.appendChild(replyBox);

    return editBox;
}

function createEditActions(draftId) {
    var btnWrap = document.createElement('div');
    btnWrap.className = 'draft-edit-actions';

    var saveBtn = document.createElement('button');
    saveBtn.className = 'stage-btn';
    saveBtn.textContent = 'Save';
    saveBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        saveDraftEdit(draftId);
    });
    btnWrap.appendChild(saveBtn);

    var cancelBtn = document.createElement('button');
    cancelBtn.className = 'draft-cancel-btn';
    cancelBtn.textContent = 'Cancel';
    cancelBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        cancelDraftEdit(draftId);
    });
    btnWrap.appendChild(cancelBtn);

    return btnWrap;
}

function saveDraftEdit(draftId) {
    if (!isValidUUID(draftId)) return;

    var textarea = document.getElementById('draft-edit-' + draftId);
    if (!textarea) return;

    var body = sanitizeBodyText(textarea.value.trim());

    // Unicode-safe truncation using for..of (iterates code points, not UTF-16
    // code units) with early termination — no O(n) Array.from allocation.
    body = unicodeTruncate(body, MAX_BODY_LENGTH);

    // Let Swift model be the single source of truth for empty-body-means-delete.
    // Post editComment for all cases; the coordinator + PRViewModel handle deletion.
    try {
        postToSwift({ action: 'editComment', id: draftId, body: body });
        // Clear error state only after successful post — avoids clearing stale errors
        // if postToSwift throws synchronously before the message is sent.
        clearSaveError(draftId);
    } catch (err) {
        // Distinguish error types so users get actionable messages:
        // TypeError typically indicates the message bridge is unavailable (network-ish),
        // everything else is a generic save failure.
        var isNetworkish = err instanceof TypeError;
        var userMsg = isNetworkish
            ? 'Connection to app lost — click Retry'
            : 'Save failed — click Retry or try again';
        reportToSwift('saveDraftEdit', 'failed to save draft ' + draftId + ' (' +
            (isNetworkish ? 'bridge' : 'other') + '): ' + String(err).slice(0, 200));
        showSaveError(draftId, userMsg);
    }
}

// Show save error feedback with a retry button so users aren't stuck.
// `message` provides context-specific guidance (network vs generic failure).
function showSaveError(draftId, message) {
    var textarea = document.getElementById('draft-edit-' + draftId);
    if (!textarea) return;

    textarea.classList.add('save-error');
    textarea.setAttribute('title', message || 'Save failed — click Retry or try again');

    // Add a retry button if one doesn't already exist
    var editBox = textarea.closest('.draft-edit-box');
    if (!editBox || editBox.querySelector('.save-retry-btn')) return;

    var actionsWrap = editBox.querySelector('.draft-edit-actions');
    if (!actionsWrap) return;

    var retryBtn = document.createElement('button');
    retryBtn.className = 'stage-btn save-retry-btn';
    retryBtn.textContent = 'Retry';
    retryBtn.addEventListener('click', function(e) {
        e.stopPropagation();
        saveDraftEdit(draftId);
    });
    actionsWrap.insertBefore(retryBtn, actionsWrap.firstChild);
}

// Clear save error state and remove retry button
function clearSaveError(draftId) {
    var textarea = document.getElementById('draft-edit-' + draftId);
    if (textarea) {
        textarea.classList.remove('save-error');
        textarea.removeAttribute('title');
    }

    var editBox = findByDraftId('draft-edit-box', draftId);
    if (editBox) {
        var retryBtn = editBox.querySelector('.save-retry-btn');
        if (retryBtn) retryBtn.remove();
    }
}

// Unicode-safe string truncation. Single pass: builds the result incrementally
// while iterating code points (not UTF-16 code units). O(maxLen).
// Wrapped in try-catch: malformed Unicode sequences (e.g. lone surrogates) can
// cause the for..of iterator to throw on some engines.
//
// Optimization: when the string is already within limit, returns the original
// reference instead of the incrementally-built copy. This is safe because JS
// strings are immutable — no aliasing hazard.
function unicodeTruncate(str, maxLen) {
    try {
        var result = '';
        var count = 0;
        for (var ch of str) {
            if (count >= maxLen) return result;
            result += ch;
            count++;
        }
        return str; // already within limit — return original to avoid allocation
    } catch (err) {
        // Fallback: slice by UTF-16 code units (may split surrogates, but
        // that's better than losing the entire string).
        reportToSwift('unicodeTruncate', 'iterator failed, falling back to slice: ' + err);
        return str.slice(0, maxLen);
    }
}

function cancelDraftEdit(draftId) {
    if (!isValidUUID(draftId)) return;

    var editBox = findByDraftId('draft-edit-box', draftId);
    if (editBox) editBox.remove();

    var indicator = findByDraftId('draft-indicator', draftId);
    if (indicator) indicator.classList.remove('hidden');
}

function removeDraftFromWebView(draftId) {
    if (!isValidUUID(draftId)) {
        reportToSwift('removeDraftFromWebView', 'invalid UUID: ' + draftId);
        return;
    }
    postToSwift({ action: 'removeComment', id: draftId });
}

// Walk up the DOM to find the nearest .line-block ancestor
function findParentLineBlock(node) {
    var el = node;
    while (el && el !== document.body) {
        if (el.nodeType === 1 && el.classList && el.classList.contains('line-block')) {
            return el;
        }
        el = el.parentNode;
    }
    return null;
}

// Walk up to find an ancestor with a specific class
function findParentWithClass(node, className) {
    var el = node;
    while (el && el !== document.body) {
        if (el.nodeType === 1 && el.classList && el.classList.contains(className)) {
            return el;
        }
        el = el.parentNode;
    }
    return null;
}
