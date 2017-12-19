;;; citeproc.el --- a CSL 1.0.1 Citation Processor for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2017 András Simonyi

;; Author: András Simonyi <andras.simonyi@gmail.com>
;; Maintainer: András Simonyi <andras.simonyi@gmail.com>
;; URL: https://github.com/andras-simonyi/citeproc-el
;; Keywords: bibliography citation cite csl
;; Package-Requires: ((emacs "25") (dash "2.13") (s "1.12.0") (f "0.18.0") (queue "0.2"))
;; Version: 0.1

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Citeproc-el is a CSL 1.0.1 Citation Processor written in Emacs Lisp. See the
;; accompanying README for documentation.

;;; Code:

(require 'dash)
(require 'cl-lib)
(require 'queue)

(require 'cpr-locale)
(require 'cpr-style)
(require 'cpr-choose)
(require 'cpr-generic-elements)
(require 'cpr-context)
(require 'cpr-itemdata)
(require 'cpr-proc)
(require 'cpr-cite)
(require 'cpr-sort)
(require 'cpr-formatters)
(require 'cpr-itemgetters)

(defvar cpr-disambiguation-cite-pos 'last
  "Which cite position should be the basis of cite disambiguation.
Possible values are 'last, 'first and 'subsequent.")

(defun cpr-proc-create (style it-getter loc-getter &optional loc force-loc)
  "Return a CSL processor for a given STYLE, IT-GETTER and LOC-GETTER.
STYLE is either a path to a CSL style file or a CSL style as a
  string.
IT-GETTER is a function that takes a list of itemid strings as
  its sole argument and returns an alist in which the given
  itemids are the keys and the values are the parsed csl json
  descriptions of the corresponding bibliography items (keys are
  symbols, arrays and hashes should be represented as lists and
  alists, respecively).
LOC-GETTER is a function that takes a locale string (e.g.
  \"en_GB\") as an argument and returns a corresponding parsed
  CSL locale (in the same format as IT-GETTER).
Optional LOC is the locale to use if the style doesn't specify a
  default one. Defaults to \"en-US\".
If optional FORCE-LOC is non-nil then use locale LOC even if
  STYLE specifies a different one as default. Defaults to nil."
  (let ((style (cpr-style-create style loc-getter loc force-loc))
	(names (make-hash-table :test 'equal))
	(itemdata (make-hash-table :test 'equal))
	(citations (make-queue)))
    (cpr-proc--create :style style :getter it-getter :names names
		      :itemdata itemdata :citations citations :finalized t)))

(defun cpr-render-citations (proc format &optional no-links)
  "Render all citations in PROC in the given FORMAT.
Return a list of formatted citations. If optional NO-LINKS is
non-nil then don't link cites to the referred items."
  (when (not (cpr-proc-finalized proc))
    (cpr-proc-finalize proc))
  (--map (cpr-citation--render-formatted-citation it proc format no-links)
	 (queue-head (cpr-proc-citations proc))))

;;; For one-off renderings

(defun cpr-style-create (style locale-getter &optional locale force-locale)
  "Compile style in STYLE into a cpr-style struct.
STYLE is either a path to a CSL style file, or a style as a string.
LOCALE-GETTER is a getter function for locales, the optional
LOCALE is a locale to prefer. If FORCE-LOCALE is non-nil then use
  LOCALE even if the style's default locale is different."
  (-let* (((year-suffix . parsed-style) (cpr-style-parse style))
	  (default-locale (alist-get 'default-locale (cadr parsed-style)))
	  (preferred-locale (if force-locale locale (or default-locale
							locale
							"en-US")))
	  (act-parsed-locale (funcall locale-getter preferred-locale))
	  (act-locale (alist-get 'lang (cadr act-parsed-locale)))
	  (style (cpr-style-create-from-locale parsed-style (not (not year-suffix)) act-locale)))
    (cpr-style--update-locale style act-parsed-locale)
    (cpr-style--set-opt-defaults style)
    style))

;; FIXME: this should be rethought -- should we apply the specific wrappers as
;; well?
(defun cpr-render-varlist (var-alist style mode format)
  "Render an item described by VAR-ALIST with STYLE.
MODE is either 'bib or 'cite,
FORMAT is a symbol representing a supported output format."
  (funcall (cpr-formatter-rt (cpr-formatter-for-format format))
	   (cpr-rt-cull-spaces-puncts
	    (cpr-rt-finalize
	     (cpr--render-varlist-in-rt var-alist style mode 'display t)))))

(defun cpr-proc-append-citations (proc citations)
  "Append CITATIONS to the queue of citations in PROC.
CITATIONS is a list of `cpr-citation' structures."
  (let ((itemdata (cpr-proc-itemdata proc))
	ids)
    ;; Collect new itemids
    (dolist (citation citations)
      (dolist (cite (cpr-citation-cites citation))
	(push (alist-get 'id cite) ids)))
    (let* ((uniq-ids (delete-dups (nreverse ids))) ; reverse pushed ids
	   (new-ids (--remove (gethash it itemdata) uniq-ids)))
      ;; Add all new items in one pass
      (cpr-proc-put-items-by-id proc new-ids)
      ;; Add itemdata to the cite structs and add them to the cite queue.
      (dolist (citation citations)
	(setf (cpr-citation-cites citation)
	      (--map (cons (cons 'itd (gethash (alist-get 'id it) itemdata)) it)
		     (cpr-citation-cites citation)))
	(queue-append (cpr-proc-citations proc) citation))
      (setf (cpr-proc-finalized proc) nil))))

;;;; Bibliography rendering

(defun cpr--bib-opts-to-formatting-params (bib-opts)
  "Convert BIB-OPTS to a formatting parameters alist."
  (let ((result
	 (cl-loop
	  for (opt . val) in bib-opts
	  if (memq opt
		   '(hanging-indent line-spacing entry-spacing second-field-align))
	  collect (cons opt
			(pcase val
			  ("true" t)
			  ("false" nil)
			  ("flush" 'flush)
			  ("margin" 'margin)
			  (_ (string-to-number val)))))))
    (if (alist-get 'second-field-align result)
	result
      (cons (cons 'second-field-align nil)
	    result))))

(defun cpr--bib-max-offset (rb)
  "Return the maximal first field width in rich-text bibliography RB."
  (cl-loop for raw-item in rb maximize
	   (length (cpr-rt-to-plain (cadr raw-item)))))

(defun cpr--bib-subsequent-author-substitute (bib s)
  "Substitute S for subsequent author(s) in BIB.
BIB is a list of bib entries in rich-text format. Return the
modified bibliography."
  (let (prev-author)
    (--map
     (let ((author
	    (cpr-rt-find-first-node
	     it
	     (lambda (x)
	       (and (consp x) (assoc 'rendered-names (car x)))))))
       (if (equal author prev-author)
	   (car (cpr-rt-replace-first-names it s))
	 (prog1 it (setq prev-author author))))
     bib)))

(defun cpr-render-bib (proc format &optional no-link-targets)
  "Render a bibliography of items in PROC in FORMAT.
If optional NO-LINK-TARGETS is non-nil then don't generate
targets for citatation links.
  Returns a (FORMATTED-BIBLIOGRAPHY . FORMATTING-PARAMETERS) cons
cell, in which FORMATTING-PARAMETERS is an alist containing the
the following formatting parameters keyed to the parameter names
as symbols:
  max-offset (integer): The width of the widest first field in the
bibliography, measured in characters.
  line-spacing (integer): Vertical line distance specified as a
multiple of standard line height.
  entry-spacing (integer): Vertical distance between
bibliographic entries, specified as a multiple of standard line
height.
  second-field-align ('flush or 'margin): The position of
second-field alignment.
  hanging-indent (boolean): Whether the bibliography items should
be rendered with hanging-indents."
  (if (null (cpr-style-bib-layout (cpr-proc-style proc)))
      "[NO BIBLIOGRAPHY LAYOUT IN CSL STYLE]"
    (when (not (cpr-proc-finalized proc))
      (cpr-proc-finalize proc))
    (let* ((formatter (cpr-formatter-for-format format))
	   (rt-formatter (cpr-formatter-rt formatter))
	   (bib-formatter (cpr-formatter-bib formatter))
	   (bibitem-formatter (cpr-formatter-bib-item formatter))
	   (style (cpr-proc-style proc))
	   (bib-opts (cpr-style-bib-opts style))
	   (punct-in-quote (string= (alist-get 'punctuation-in-quote
					       (cpr-style-locale-opts style))
				    "true"))
	   (sorted (cpr-proc-get-itd-list proc))
	   (raw-bib (--map (cpr-rt-finalize
			    (cpr--render-varlist-in-rt
			     (cpr-itemdata-varvals it)
			     style 'bib 'display no-link-targets)
			    punct-in-quote)
			   sorted))
	   (substituted
	    (if-let (subs-auth-subst
		     (alist-get 'subsequent-author-substitute bib-opts))
		(cpr--bib-subsequent-author-substitute raw-bib subs-auth-subst)
	      raw-bib))
	   (max-offset (if (alist-get 'second-field-align bib-opts)
			   (cpr--bib-max-offset raw-bib)
			 0)))
      (let ((format-params (cons (cons 'max-offset max-offset)
				 (cpr--bib-opts-to-formatting-params bib-opts))))
	(cons (funcall bib-formatter
		       (--map (funcall bibitem-formatter
				       (funcall rt-formatter (cpr-rt-cull-spaces-puncts it))
				       format-params)
			      substituted)
		       format-params)
	      format-params)))))

(defun cpr--render-varlist-in-rt (var-alist style mode render-mode &optional no-item-no)
  "Render an item described by VAR-ALIST with STYLE in rich-text.
Does NOT finalize the rich-text rendering. MODE is either 'bib or
'cite, RENDER-MODE is 'display or 'sort. If NO-ITEM-NO is non-nil
then don't add item-no information."
  (if-let ((unprocessed-id (alist-get 'unprocessed-with-id var-alist)))
      ;; Itemid received no associated csl fields from the getter!
      (list nil (concat "NO_ITEM_DATA:" unprocessed-id))
    (let* ((context (cpr-context-create var-alist style mode render-mode))
	   (layout-fun-accessor (if (eq mode 'cite) 'cpr-style-cite-layout
				  'cpr-style-bib-layout))
	   (layout-fun (funcall layout-fun-accessor style)))
      (if (null layout-fun) "[NO BIBLIOGRAPHY LAYOUT IN CSL STYLE]"
	(let* ((year-suffix (alist-get 'year-suffix var-alist))
	       (rendered (funcall layout-fun context))
	       (itemid-attr (if (eq mode 'cite) 'cited-item-no 'bib-item-no))
	       (itemid-attr-val (cons itemid-attr
				      (alist-get 'citation-number var-alist))))
	  ;; Add item-no information as the last attribute
	  (unless no-item-no
	    (cond ((consp rendered) (setf (car rendered)
					  (-snoc (car rendered) itemid-attr-val)))
		  ((stringp rendered) (setq rendered
					    (list (list itemid-attr-val) rendered)))))
	  ;; Add year-suffix if needed
	  (if year-suffix
	      (car (cpr-rt-add-year-suffix
		    rendered
		    ;; year suffix is empty if already rendered by var just to delete the
		    ;; suppressed date
		    (if (cpr-style-uses-ys-var style) "" year-suffix)))
	    rendered))))))

;;;; General CSL

(defconst cpr--number-vars
  '(chapter-number collection-number edition issue number number-of-pages
		   number-of-volumes volume citation-number first-reference-note-number)
  "CLS number variables.")

(defconst cpr--date-vars
  '(accessed container event-date issued original-date submitted)
  "CLS date variables.")

(defconst cpr--name-vars
  '(author collection-editor composer container-author director editor editorial-director
	   illustrator interviewer original-author recipient reviewed-author translator)
  "CLS name variables.")

(provide 'citeproc)

;;; citeproc.el ends here