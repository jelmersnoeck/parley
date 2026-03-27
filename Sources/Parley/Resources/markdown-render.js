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

// Post message to Swift
function postToSwift(msg) {
    window.webkit.messageHandlers.parley.postMessage(msg);
}

// Sanitize HTML to prevent XSS
function sanitize(html) {
    return DOMPurify.sanitize(html, { ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'a', 'code', 'pre', 'p', 'br', 'ul', 'ol', 'li', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'img', 'hr', 'del', 'input', 'span', 'div', 'dl', 'dt', 'dd', 'sup', 'sub'], ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'class', 'type', 'checked', 'disabled', 'width', 'height'] });
}

// Render markdown with line-level anchoring
function renderMarkdown(markdown, threads, drafts) {
    commentThreads = threads || [];
    draftComments = drafts || [];

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

            var badge = document.createElement('span');
            badge.className = 'badge';
            badge.textContent = 'DRAFT';
            draftEl.appendChild(badge);

            var bodySpan = document.createElement('span');
            bodySpan.textContent = draft.body;
            draftEl.appendChild(bodySpan);

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
        findParentWithClass(anchorNode, 'draft-indicator')) {
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
        clone.querySelectorAll('.add-comment-btn, .comment-indicator, .comment-thread, .draft-indicator, .new-comment-box').forEach(function(el) { el.remove(); });
        var text = clone.textContent.trim();
        if (text) parts.push(text);
    });
    return parts.join('\n');
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
