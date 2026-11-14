function tf = aisNamesMatch(broadcast, listed)
%aisNamesMatch True if an AIS broadcast name plausibly is the listed vessel name.
%   AIS names are upper case, at most 20 characters, and often abbreviated
%   ("ADM RICHARD E BENNIS" for "Admiral Richard E. Bennis"). Names match when
%   they are equal ignoring case, spacing and punctuation, or when they have
%   the same words in order with each word a prefix of the other (abbreviation).
%   A broadcast name cut off at 20 characters may have fewer words, the
%   last one truncated.

words = @(s) split(strtrim(regexprep(upper(string(s)), '[^A-Z0-9 ]', ' ')));
a = words(broadcast);
b = words(listed);
a = a(strlength(a) > 0);
b = b(strlength(b) > 0);
tf = false;
if isempty(a) || isempty(b), return; end
if strjoin(a, '') == strjoin(b, '')
    tf = true;
    return
end
truncated = strlength(strjoin(a, ' ')) >= 19;
if truncated && startsWith(strjoin(b, ''), strjoin(a, ''))
    tf = true;
    return
end
truncated = truncated && numel(a) < numel(b);
if numel(a) ~= numel(b) && ~truncated, return; end
for k = 1:numel(a)
    if ~(startsWith(a(k), b(k)) || startsWith(b(k), a(k)))
        return
    end
end
tf = true;
end
